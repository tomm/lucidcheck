# XXX need way to set types of abstract methods, and enforce in implementation
class Scope
  def initialize(selftype)
    @namespace = {}
    @selftype = selftype
  end

  def in_class
    @selftype
  end

  #: fn(String) -> Tuple<Rbindable, Rbindable>
  def lookup(name)
    [@namespace[name], @selftype]
  end

  #: fn(Rbindable, ?String)
  def define(rbindable, bind_to=nil)
    @namespace[bind_to || rbindable.name] = rbindable
  end

  def each_value
    @namespace.each_value { |v| yield v }
  end

  def lookup_super; raise NotImplementedError end
  def define_lvar(name, rbindable); raise NotImplementedError end
  def define_ivar(name, rbindable); raise NotImplementedError end
  def is_identical_fn_call_in_stack?(node, block); raise NotImplementedError end
end

# Used to forbid sloppy scoping in 'if', 'case', 'rescue' etc
class WeakScope < Scope
  def initialize(parent_scope)
    super(parent_scope.in_class)
    @parent = parent_scope
  end

  def lookup(name)
    r = super(name)
    r[0].nil? ? @parent.lookup(name) : r
  end

  def define_lvar(name, rbindable)
    if @parent.lookup(name)[0] == nil
      define(rbindable, name)
    else
      raise CheckerBug, "tried to define shadowing variable on WeakScope"
    end
  end

  # delegate to @parent scope
  def lookup_super; @parent.lookup_super end
  def is_identical_fn_call_in_stack?(node, block); @parent.is_identical_fn_call_in_stack?(node, block) end
  def define_ivar(rbindable); @parent.define_ivar(rbindable) end
  def passed_block; @parent.passed_block end
  def is_constructor; @parent.is_constructor end
  def caller_node; @parent.caller_node end
  def in_class; @parent.in_class end
  def add_return_val(val); @parent.add_return_val(val) end
end

class FnScope < Scope
  attr_reader :passed_block, :is_constructor, :caller_node, :return_vals
  #: fn(Rmetaclass | Rclass, Rblock | nil)
  def initialize(caller_node, caller_scope, fn_body_node, in_class, parent_scope, passed_block, is_constructor: false)
    super(in_class)
    @parent_scope = parent_scope
    @passed_block = passed_block
    @is_constructor = is_constructor
    @caller_node = caller_node
    @caller_scope = caller_scope
    @fn_body_node = fn_body_node
    @return_vals = []
  end

  def add_return_val(val)
    @return_vals << val
  end

  def is_identical_fn_call_in_stack?(node, block)
    @fn_body_node.equal?(node) && @caller_scope.passed_block == block ||
    @caller_scope && @caller_scope.is_identical_fn_call_in_stack?(node, block)
  end

  def lookup_super
    if in_class.parent&.metaclass
      in_class.parent.metaclass.lookup('new')
    else
      [nil, nil]
    end
  end

  #: fn(String) > [Rbindable, Rbindable]
  # returns       [object, scope]
  def lookup(name)
    r = super(name)
    if r[0] == nil && @parent_scope then r = @parent_scope.lookup(name) end
    if r[0] == nil then r = in_class.lookup(name) end
    r
  end

  def define_lvar(name, rbindable)
    define(rbindable, name)
  end

  def define_ivar(name, rbindable)
    in_class.define(rbindable, bind_to: name)
  end
end
