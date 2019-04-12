# XXX need way to set types of abstract methods, and enforce in implementation
class Scope
  def lookup_super; raise NotImplementedError end
  def lookup; raise NotImplementedError end
  def define_lvar(rbindable); raise NotImplementedError end
  def define_ivar(rbindable); raise NotImplementedError end
  def is_fn_body_node_in_stack(node); raise NotImplementedError end
end

# Used to forbid sloppy scoping in 'if', 'case', 'rescue' etc
class WeakScope < Scope
  def initialize(parent_scope)
    @parent = parent_scope
    @local_scope = {}
  end

  def lookup(name)
    r = [@local_scope[name], @parent.in_class]
    if r[0] == nil then @parent.lookup(name) else r end
  end

  def define_lvar(rbindable)
    if @parent.lookup(rbindable)[0] == nil
      @local_scope[rbindable.name] = rbindable
    else
      raise CheckerBug, "tried to define shadowing variable on WeakScope"
    end
  end

  # delegate to @parent scope
  def lookup_super; @parent.lookup_super end
  def is_fn_body_node_in_stack(node); @parent.is_fn_body_node_in_stack(node) end
  def define_ivar(rbindable); @parent.define_ivar(rbindable) end
  def passed_block; @parent.passed_block end
  def is_constructor; @parent.is_constructor end
  def caller_node; @parent.caller_node end
  def in_class; @parent.in_class end
  def add_return_val(val); @parent.add_return_val(val) end
end

class FnScope < Scope
  attr_reader :passed_block, :is_constructor, :caller_node, :in_class, :return_vals
  #: fn(Rmetaclass | Rclass, Rblock | nil)
  def initialize(caller_node, caller_scope, fn_body_node, in_class, parent_scope, passed_block, is_constructor: false)
    @in_class = in_class
    @local_scope = {}
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

  def is_fn_body_node_in_stack(node)
    @fn_body_node.equal?(node) || @caller_scope && @caller_scope.is_fn_body_node_in_stack(node)
  end

  def lookup_super
    if @in_class.parent&.metaclass
      @in_class.parent.metaclass.lookup('new')
    else
      [nil, nil]
    end
  end

  #: fn(String) > [Rbindable, Rbindable]
  # returns       [object, scope]
  def lookup(name)
    r = [@local_scope[name], @in_class]
    if r[0] == nil && @parent_scope then r = @parent_scope.lookup(name) end
    if r[0] == nil then r = @in_class.lookup(name) end
    r
  end

  def define_lvar(rbindable)
    @local_scope[rbindable.name] = rbindable
  end

  def define_ivar(rbindable)
    @in_class.define(rbindable)
  end
end
