# Something you can assign to a variable
class Rbindable
  attr_accessor :name
  attr_reader :type
  def initialize(name, type)
    @name = name
    @type = type
    if type && !type.kind_of?(Rbindable)
      raise "Weird type passed to Rbindable.initialize: #{type} (#{type.class})"
    end
  end

  def to_s
    @name
  end

  def new_inst
    self
  end

  def rinstance_of?(other)
    false
  end

  def parent
    nil
  end

  def add_template_params_scope(mut_template_types)
  end
end

# when type inference fails
class Rundefined < Rbindable
  def initialize
    super(:undefined, nil)
  end
end

class Rretvoid < Rbindable
  def initialize
    super(:retvoid, nil)
  end
end

class Rrecursion < Rbindable
  def initialize
    super(:unannotated_recursive_function, nil)
  end

  def lookup(name)
    [nil, nil]
  end
end

class TemplateType < Rbindable
  def initialize
    super(:generic, nil)
  end

  def lookup(name)
    [nil, nil]
  end
end

class SelfType < Rbindable
  def initialize
    super(:genericSelf, nil)
  end
end

class Rlvar < Rbindable
end

class Rconst < Rbindable
end

class Rfunc < Rbindable
  attr_accessor :node, :body, :sig, :block_sig
  attr_reader :is_constructor

  #: fn(String, Rbindable, Array[Rbindable])
  def initialize(name, return_type, anon_args = [], is_constructor: false, block_sig: nil)
    super(name, nil)
    @sig = FnSig.new(return_type, anon_args)
    @block_sig = block_sig
    @node = nil
    @is_constructor = is_constructor
  end

  def type_unknown?
    @sig.type_unknown?
  end

  # named as in def my_func(x, y, z). ie not keyword args
  #: fn(Array[[String, Rbindable]])
  def add_named_args(arg_name_type)
    @sig.add_named_args(arg_name_type)
  end

  def return_type=(type)
    @sig.return_type = type
  end

  def return_type
    @sig.return_type
  end
end

class Rmetaclass < Rbindable
  attr_reader :metaclass_for
  def initialize(parent_name, metaclass_for)
    super("#{parent_name}:Class", nil)
    @namespace = {}
    @metaclass_for = metaclass_for
  end

  def lookup(method_name)
    [@namespace[method_name], self]
  end

  def define(rbindable)
    @namespace[rbindable.name] = rbindable
  end
end

class Rclass < Rbindable
  attr_reader :metaclass, :namespace, :parent
  def initialize(name, parent_class, template_params: [])
    @metaclass = Rmetaclass.new(name, self)
    super(name, @metaclass)
    @parent = parent_class
    @namespace = {}
    @template_params = template_params
  end

  def rinstance_of?(other)
    if other.instance_of?(Rclass)
      p = @parent
      while p != nil && p != other do; p = p.parent end
      p == other
    else
      false
    end
  end

  def add_template_params_scope(mut_template_types)
  end

  def lookup(method_name)
    m = @namespace[method_name]
    if m
      [m, self]
    elsif @parent
      @parent.lookup(method_name)
    else
      [nil, nil]
    end
  end

  def define(rbindable, bind_to: nil)
    @namespace[bind_to || rbindable.name] = rbindable
  end

  def [](specialization)
    Rconcreteclass.new(self, @template_params.zip(specialization).to_h)
  end

  def new_generic_specialization
    self[@template_params]
  end
end

class Rconcreteclass < Rbindable
  attr_reader :class, :specialization
  def initialize(_class, specialization)
    @specialization = specialization
    @class = _class
  end

  def new_inst
    Rconcreteclass.new(@class, @specialization.clone)
  end

  def name
    "#{@class.name}<#{@specialization.map {|v|v[1].name}.join(',')}>"
  end

  def add_template_params_scope(mut_template_types)
    mut_template_types.merge!(@specialization)
  end

  def is_fully_specialized?
    !@specialization.map {|kv| kv[1].is_a?(TemplateType)}.any?
  end
  def type
    @class.type
  end
  def lookup(method_name)
    @class.lookup(method_name)
  end
  def define(rbindable)
    @class.define(rbindable)
  end
  def eql?(other)
    if is_fully_specialized?
      @class == other.class && @specialization == other.specialization
    else
      self.equal?(other)
    end
  end
  def ==(other)
    self.eql?(other)
  end
  # returns errors
  def specialize(template_param, concrete_type)
    t = @specialization[template_param]
    if t.is_a?(TemplateType)
      @specialization[template_param] = concrete_type
      true
    else
      t == concrete_type
    end
  end
  # specialize from template_params from another Rconcreteclass
  def new_inst_specialize(template_param, concrete_type)
    @specialization.each_pair { |k,v|
      @specialization[k] = concrete_type if v == template_param
    }
  end
end

class Rsumtype < Rbindable
  attr_reader :options
  #: fn(Array[Rbindable])
  def initialize(types)
    super(nil, nil)
    @options = types.sort_by { |a| a.name.to_s }
    # base_type is most recent common parent type of all in 'types'
    # XXX should compute rather than pass in
    @base_type = most_recent_common_ancestor(types)
  end

  def lookup(name)
    @base_type&.lookup(name) || [nil, nil]
  end

  def name
    @options.map(&:name).join(' | ')
  end

  def is_optional
    !!@options.detect { |o| o.name == 'Nil' }
  end

  def to_non_optional
    sum_of_types(@options.reject { |o| o.name == 'Nil' })
  end

  def ==(other)
    if other.is_a?(Rsumtype)
      other.options.map { |o| @options.include?(o) }.all?
    else
      @options.map { |o| o == other }.any?
    end
  end
end

def most_recent_common_ancestor(types)
  a = types.first
  while a != nil && !types.map { |t| t.rinstance_of?(a) }.all? do
    a = a.parent
  end
  a
end

# Only returns a sum type if number of types > 1
def sum_of_types(types, fn_ret: false)
  t = types.flatten
           .map { |t| if t.is_a?(Rsumtype) then t.options else [t] end }
           .flatten
           .uniq
  t.reject! { |t| t.is_a?(Rretvoid) } if fn_ret
  case t.length
  when 0
    raise "sum_type with zero cases"
  when 1
    t.first
  else
    Rsumtype.new(t)
  end
end
