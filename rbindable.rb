# Something you can assign to a variable
class Rbindable
  attr_accessor :name
  def initialize(name)
    @name = name
  end

  def new_inst
    self
  end

  def supertype_of?(other)
    false
  end

  def is_specialization_of?(other)
    false
  end

  def parent
    nil
  end

  def add_template_params_scope(mut_template_types)
  end
end

class Rbuiltin < Rbindable
  attr_reader :sig
  def initialize(name, sig, fn)
    super(name)
    @fn = fn
    # only actually need the args bit of sig. return type determined by what call() returns
    @sig = sig
  end

  def call(*args)
    @fn.call(*args)
  end
end

# when type inference fails
class Rundefined < Rbindable
  def initialize
    super(:undefined)
  end
end

class Rretvoid < Rbindable
  def initialize
    super(:retvoid)
  end
end

class Rrecursion < Rbindable
  def initialize
    super(:unannotated_recursive_function)
  end

  def lookup(name)
    [nil, nil]
  end
end

class TemplateType < Rbindable
  def initialize
    super(:generic)
  end

  def lookup(name)
    [nil, nil]
  end

  def supertype_of?(other)
    self.equal?(other)
  end
end

class SelfType < Rbindable
  def initialize
    super(:genericSelf)
  end
end

class Rfunc < Rbindable
  attr_accessor :node, :body, :sig, :block_sig, :checked, :can_autocheck, :is_constructor

  #: fn(String, Rbindable, Array<Rbindable>)
  def initialize(name, return_type, anon_args = [], is_constructor: false, block_sig: nil, checked: true, can_autocheck: false)
    super(name)
    @sig = FnSig.new(return_type, anon_args)
    @block_sig = block_sig
    @node = nil
    @is_constructor = is_constructor
    @checked = checked
    @can_autocheck = can_autocheck
  end

  def type_unknown?
    @sig.type_unknown?
  end

  # named as in def my_func(x, y, z). ie not keyword args
  #: fn(Array<Tuple<String, Rbindable>>)
  def add_named_args(arg_name_type)
    @sig.add_named_args(arg_name_type)
  end

  #: fn(Kwtype)
  def set_kwargs(kwargs)
    @sig.set_kwargs(kwargs)
  end

  #: fn(Array<Tuple<String, Rbindable>>)
  def add_opt_args(arg_name_type)
    @sig.add_opt_args(arg_name_type)
  end

  def return_type=(type)
    @sig.return_type = type
  end

  def return_type
    @sig.return_type
  end
end

class Rmodule < Rbindable
  def initialize(name)
    super(name)
    @namespace = {}
  end

  def lookup(method_name)
    [@namespace[method_name], self]
  end

  #: fn(Rbindable)
  def define(rbindable, bind_to: nil)
    @namespace[bind_to || rbindable.name] = rbindable
  end
end

class Rmetaclass < Rbindable
  attr_reader :metaclass_for
  def initialize(parent_name, metaclass_for)
    super("#{parent_name}:Class")
    @namespace = {}
    @metaclass_for = metaclass_for
  end

  def lookup(method_name)
    [@namespace[method_name], self]
  end

  #: fn(Rbindable)
  def define(rbindable)
    @namespace[rbindable.name] = rbindable
  end
end

class Rclass < Rbindable
  attr_reader :metaclass, :namespace, :parent, :template_params
  def initialize(name, parent_class, template_params: [])
    @metaclass = Rmetaclass.new(name, self)
    super(name)
    @parent = parent_class
    @namespace = {}
    @template_params = template_params
  end

  def max_template_params
    @template_params.length
  end

  def supertype_of?(other)
    if self === other
      true
    elsif other.instance_of?(Rclass)
      p = other.parent
      while p != nil && p != self do; p = p.parent end
      p == self
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
    if rbindable.is_a?(Rmetaclass)
      @namespace[bind_to || rbindable.metaclass_for.name] = rbindable
      rbindable.metaclass_for
    else
      @namespace[bind_to || rbindable.name] = rbindable
      rbindable
    end
  end

  # permits under-specialization. this is needed for tuples, which have
  # have 8 generic params (max tuple length 8) but n-tuple only uses n
  def [](specialization)
    Rconcreteclass.new(
      self, 
      specialization.zip(@template_params)
                    .map {|kv| [kv[1], kv[0]]}
                    .to_h
    )
  end

  def new_generic_specialization
    self[@template_params]
  end
end

class Rconcreteclass < Rbindable
  attr_reader :template_class, :specialization
  #: fn(Rclass, Hash<TemplateType, Rbindable>)
  def initialize(_template_class, specialization)
    @specialization = specialization
    @template_class = _template_class
  end

  def new_inst
    Rconcreteclass.new(@template_class, @specialization.clone)
  end

  def name
    "#{@template_class.name}<#{@specialization.map {|v|v[1].name}.join(',')}>"
  end

  def add_template_params_scope(mut_template_types)
    mut_template_types.merge!(@specialization)
  end

  def is_fully_specialized?
    !@specialization.map {|kv| kv[1].is_a?(TemplateType)}.any?
  end
  def type
    @template_class.type
  end
  def lookup(method_name)
    @template_class.lookup(method_name)
  end

  #: fn(Rbindable)
  def define(rbindable)
    @template_class.define(rbindable)
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

  def supertype_of?(other)
    if other.is_a?(Rconcreteclass) && other.template_class.equal?(template_class)
      if @specialization.keys == other.specialization.keys
        @specialization.keys.map { |k|
          @specialization[k].supertype_of?(other.specialization[k])
        }.all?
      else
        false
      end
    else
      false
    end
  end

  def is_specialization_of?(abstract_class)
    @template_class.equal?(abstract_class)
  end
end

class Rsumtype < Rbindable
  attr_reader :options
  #: fn(Array<Rbindable>)
  def initialize(types)
    super(nil)
    @options = types.sort_by { |a| a.name.to_s }
    # base_type is most recent common parent type of all in 'types'
    # XXX should compute rather than pass in
    @base_type = most_recent_common_ancestor(types)
  end

  def supertype_of?(other)
    if other.is_a?(Rsumtype)
      other.options.map { |o| @options.find { |s| s.supertype_of?(o) } }.all?
    else
      @options.find { |o| o.supertype_of?(other) } != nil
    end
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
end

def most_recent_common_ancestor(types)
  a = types.first
  while a != nil && !types.map { |t| a.supertype_of?(t) }.all? do
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
