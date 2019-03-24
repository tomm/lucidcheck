#!/usr/bin/env ruby
require 'parser/current'
require 'pry'
require 'set'

# type annotation formats that could be parsed with ruby parser:
# String | Integer
# fn(Integer,String) > String
# fn(fn() > String)
# Array[Integer]
# [Integer, String, Boolean]
# fn[T].(T,T) > T
# fn[T,U].(fn(T) > U, Array[T]) > Array[U]

class FnScope
  #: fn(Rmetaclass | Rclass)
  def initialize(in_class)
    @in_class = in_class
    @local_scope = {}
  end

  def lookup(name)
    o = @local_scope[name]
    if o then o else @in_class.lookup(name) end
  end

  def define(rscopebinding)
    @local_scope[rscopebinding.name] = rscopebinding
  end
end

class Rthing
  attr_reader :name, :type
  def initialize(name, type)
    @name = name
    @type = type
    if type && !type.kind_of?(Rthing)
      raise "Weird type passed to Rthing.initialize: #{type} (#{type.class})"
    end
  end

  def to_s
    @name
  end
end

# when type inference fails
class Rundefined < Rthing
  def initialize
    super(:undefined, nil)
  end
end

class Rlvar < Rthing
end

class Rconst < Rthing
end

class Rfunc < Rthing
  attr_accessor :node, :body, :arg_name_type

  #: fn(String, Rthing, Array[Rthing])
  def initialize(name, return_type, anon_args = [])
    super(name, return_type)
    # [ [name, type], ... ]
    @arg_name_type = anon_args.map { |a| [nil, a] }
    @node = nil
  end

  def type_unknown?
    @arg_name_type.map{ |a| a[1] == nil }.any? || @type.kind_of?(Rundefined)
  end

  # named as in def my_func(x, y, z). ie not keyword args
  #: fn(Array[[String, Rthing]])
  def set_named_args(arg_name_type)
    @arg_name_type = arg_name_type
  end

  def return_type=(type)
    @type = type
  end

  def return_type
    @type
  end
end

class Rmetaclass < Rthing
  def initialize(parent_name)
    super("#{parent_name}:Class", nil)
    @namespace = {}
  end

  def lookup(method_name)
    @namespace[method_name]
  end

  def define(rscopebinding)
    @namespace[rscopebinding.name] = rscopebinding
  end
end

class Rclass < Rthing
  attr_reader :metaclass, :namespace
  def initialize(name, parent_class)
    @metaclass = Rmetaclass.new(name)
    super(name, @metaclass)
    @parent = parent_class
    @namespace = {}
  end

  def lookup(method_name)
    m = @namespace[method_name]
    if m
      m
    elsif @parent
      @parent.lookup(method_name)
    else
      nil
    end
  end

  def define(rscopebinding)
    @namespace[rscopebinding.name] = rscopebinding
  end
end

class Rsumtype < Rthing
  attr_reader :options
  #: fn(Array[Rthing])
  def initialize(types)
    super(types.map(&:to_s).join(' | '), nil)
    @options = types
  end

  def ==(other)
    if other.is_a?(Rsumtype)
      @options == other.options
    else
      @options.map { |o| o == other }.any?
    end
  end
end

def make_root
  robject = Rclass.new('Object', nil)
  # denny is right
  rstring  = robject.define(Rclass.new('String', robject))
  rsymbol  = robject.define(Rclass.new('Symbol', robject))
  rnil     = robject.define(Rclass.new(:nil, robject))
  rinteger = robject.define(Rclass.new('Integer', robject))
  rfloat   = robject.define(Rclass.new('Float', robject))
  rboolean = robject.define(Rclass.new('Boolean', robject))
  
  robject.define(Rfunc.new('require', rnil, [rstring]))
  robject.define(Rfunc.new('puts', rnil, [rstring]))
  robject.define(Rfunc.new('exit', rnil, [rinteger]))
  robject.define(Rfunc.new('rand', rfloat, []))

  rstring.define(Rfunc.new('upcase', rstring, []))

  rinteger.define(Rfunc.new('+', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('-', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('*', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('/', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('to_f', rfloat, []))
  rinteger.define(Rfunc.new('>', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('>=', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('<', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('<=', rboolean, [rinteger]))

  rfloat.define(Rfunc.new('+', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('-', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('*', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('/', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('>', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('>=', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('<', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('<=', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('to_i', rinteger, []))

  robject
end

class Context
  def self.error_msg(filename, e)
    "Error in #{filename} line #{e[0]&.loc&.line}: " +
      case e[1]
      when :type_unknown
        "Type '#{e[2]}' not found in this scope"
      when :fn_unknown
        "Type '#{e[3]}' has no method named '#{e[2]}'"
      when :const_unknown
        "Constant '#{e[2]}' not found in this scope"
      when :lvar_unknown
        "Local variable '#{e[2]}' not found in this scope"
      when :fn_inference_fail
        "Could not infer type of function #{e[2]}. Add a type annotation (not yet supported ;)"
      when :fn_arg_num
        "Function '#{e[2]}' expected #{e[3]} arguments but found #{e[4]}"
      when :fn_arg_type
        "Function '#{e[2]}' arguments have inferred type (#{e[3]}) but was passed (#{e[4]})"
      when :var_type
        "Cannot reassign variable '#{e[2]}' of type #{e[3]} with value of type #{e[4]}"
      when :inference_failed
        "Cannot infer type. Annotation needed."
      when :const_redef
        "Cannot redefine constant '#{e[2]}'"
      when :parse_error
        "Parse error: #{e[2]}"
      else
        e.to_s
      end
  end

  def initialize(source)
    @robject = make_root()
    @rnil = @robject.lookup(:nil)
    @rboolean = @robject.lookup('Boolean')
    @rundefined = Rundefined.new
    @scope = [@robject]
    @callstack = [FnScope.new(@robject)]
    @errors = []
    begin
      @ast = Parser::CurrentRuby.parse(source)
    rescue StandardError => e
      # XXX todo - get line number
      @errors << [nil, :parse_error, e.to_s]
    end
  end

  def check
    if @ast then n_expr(@ast) end
    check_function_type_inference_succeeded(@robject)
    @errors
  end

  private

  def check_function_type_inference_succeeded(scope)
    scope.namespace.each_value { |thing|
      if thing.kind_of?(Rfunc)
        if thing.type_unknown?
          @errors << [thing.node, :fn_inference_fail, thing.name]
        end
      elsif thing.kind_of?(Rclass)
        check_function_type_inference_succeeded(thing)
      end
    }
  end

  def push_scope(scope)
    @scope.push(scope)
  end

  def pop_scope
    @scope.pop
  end

  def scope_top
    @scope.last
  end

  def callstack_top
    @callstack.last
  end

  def pop_callstack
    @callstack.pop
  end

  #: fn(FnScope)
  def push_callstack(fnscope)
    @callstack.push(fnscope)
  end

  #: returns type
  def n_expr(node)
    case node&.type
    when nil
    when :nil
      @rnil
    when :begin
      node.children.map { |child| n_expr(child) }.last
    when :def
      n_def(node)
    when :defs # define static method
      n_defs(node)
    when :lvar
      lvar = callstack_top.lookup(node.children[0].to_s)
      if lvar == nil
        @errors << [node, :lvar_unknown, node.children[0].to_s]
        @rundefined
      else
        lvar.type
      end
    when :send
      n_send(node)
    when :ivasgn
      n_ivasgn(node)
    when :lvasgn
      n_lvasgn(node)
    when :casgn
      n_casgn(node)
    when :class
      n_class(node)
    when :module
      # ignore for now :)
    when :if
      cond = n_expr(node.children[0])
      type1 = n_expr(node.children[1])
      type2 = n_expr(node.children[2])

      if cond != @rboolean
        @errors << [node, :if_not_boolean, cond.name]
      end
      if type1 == type2
        type1
      else
        Rsumtype.new([type1, type2])
      end
    when :float
      type_lookup!(node, @robject, 'Float')
    when :int
      type_lookup!(node, @robject, 'Integer')
    when :str
      type_lookup!(node, @robject, 'String')
    when :dstr # XXX could check dstr
      type_lookup!(node, @robject, 'String')
    when :true
      type_lookup!(node, @robject, 'Boolean')
    when :false
      type_lookup!(node, @robject, 'Boolean')
    when :sym
      type_lookup!(node, @robject, 'Symbol')
    when :const
      c = scope_top.lookup(node.children[1].to_s)
      if c
        c.type
      else
        @errors << [node, :const_unknown, node.children[1].to_s]
        @rundefined
      end
    else
      raise "Unexpected #{node} at line #{node.loc.line}"
    end
  end

  def n_class(node)
    class_name = node.children[0].children[1].to_s
    parent_class_name = node.children[1]&.children&.last&.to_s
    parent_class = parent_class_name == nil ? @robject : scope_top.lookup(parent_class_name)

    new_class = Rclass.new(
      class_name,
      parent_class
    )
    scope_top.define(new_class)

    push_scope(new_class)
    r = n_expr(node.children[2])

    # define a 'new' static method if 'initialize' was not defined
    if scope_top.metaclass.lookup('new') == nil
      scope_top.metaclass.define(Rfunc.new('new', scope_top))
    end

    pop_scope()

    r
  end

  def type_lookup!(node, scope, type_identifier)
    if type_identifier == nil
      @errors << [node, :inference_failed]
      return @rundefined
    elsif type_identifier == :error
      # error happened in resolving type. don't report another error
      return @rundefined
    end

    type = scope.lookup(type_identifier)

    if type == nil then
      # type not found
      @errors << [node, :type_unknown, type_identifier]
      return @rundefined
    else
      return type
    end
  end

  # assign instance variable
  def n_ivasgn(node)
    raise "n_ivasgn not implemented at line #{node.loc.line}"
  end

  def n_lvasgn(node)
    name = node.children[0].to_s
    type = n_expr(node.children[1])

    if type == @rundefined
      # error already reported. do nothing
    elsif callstack_top.lookup(name) == nil
      callstack_top.define(Rlvar.new(name, type))
    elsif callstack_top.lookup(name).type != type
      @errors << [node, :var_type, name, callstack_top.lookup(name).type.name, type.name]
    end
  end

  def n_casgn(node)
    name = node.children[1].to_s
    type = n_expr(node.children[2])

    if type == nil
      # error already reported. do nothing
    elsif scope_top.lookup(name) == nil
      scope_top.define(Rconst.new(name, type))
    else
      @errors << [node, :const_redef, name]
    end
  end

  # returns return type of method/function (or nil if not determined)
  def n_send(node)
    name = node.children[1].to_s
    self_type = node.children[0] ? n_expr(node.children[0]) : @rnil
    if self_type != @rnil
      if self_type.kind_of?(Rundefined)
        return self_type
      else
        scope = self_type
      end
    else
      scope = scope_top
    end
    name = node.children[1].to_s
    arg_types = node.children[2..-1].map {|n| n_expr(n) }
    num_args = arg_types.length

    if scope.lookup(name) == nil
      @errors << [node, :fn_unknown, name, scope.name]
      return @rundefined
    elsif scope.lookup(name).kind_of?(Rfunc)
      return_type, errors = function_call(scope.lookup(name), node, arg_types)
      @errors = @errors + errors
      if return_type == nil and !errors.empty?
        return @rundefined
      else
        return return_type
      end
    else
      @errors << [node, :not_a_function, name]
      return @rundefined
    end
  end

  # @returns [return_type, errors]
  # updates @arg_name_type with param types if nil
  def function_call(fn, node, args)
    args.each_with_index {|a,i|
      if a == nil
        return [fn.return_type, [function_call_type_error(node, fn, args)]]
      end
    }
    if args.length != fn.arg_name_type.length
      return [fn.return_type, [[node, :fn_arg_num, fn.name, fn.arg_name_type.length, args.length]]]
    end

    # collect arg types if we know none
    if fn.type_unknown?
      args.each_with_index { |a, i| fn.arg_name_type[i][1] = a }
    end

    # check arg types. ignore first argument, since we have already resolved class lookup
    if fn.arg_name_type.map {|a| a[1]} != args
      return [fn.return_type, [function_call_type_error(node, fn, args)]]
    end

    if fn.return_type == @rundefined
      function_scope = FnScope.new(scope_top)
      # define lvars from arguments
      fn.arg_name_type.each { |a| function_scope.define(Rlvar.new(a[0], a[1])) }

      # find function return type by evaluating body with concrete argument types in scope
      push_callstack(function_scope)
      fn.return_type = n_expr(fn.body)
      pop_callstack()
    end

    [fn.return_type, []]
  end

  def function_call_type_error(node, fn, args)
    [node, :fn_arg_type, fn.name, fn.arg_name_type.map{|a|a[1]}.join(','), args.map(&:name).join(',')]
  end

  # define static method
  def n_defs(node)
    if node.children[0].type != :self
      raise "Checker bug. Expected self at #{node}"
    end
    name = node.children[1].to_s
    # [ [name, type], ... ]
    arg_name_type = node.children[2].to_a.map{|x| [x.children[0].to_s, nil] }
    # don't know types of arguments or return type yet
    fn = Rfunc.new(name, @rundefined)
    fn.set_named_args(arg_name_type)
    fn.node = node
    fn.body = node.children[3]
    scope_top.metaclass.define(fn)
  end

  def n_def(node)
    name = node.children[0].to_s
    # [ [name, type], ... ]
    arg_name_type = node.children[1].to_a.map{|x| [x.children[0].to_s, nil] }
    # define function with no known argument types (so far)
    if name == 'initialize'
      # assume return type for 'new' method
      fn = Rfunc.new('new', scope_top)
      fn.set_named_args(arg_name_type)
      fn.node = node
      fn.body = node.children[2]
      scope_top.metaclass.define(fn)
    else
      # don't know types of arguments or return type yet
      fn = Rfunc.new(name, @rundefined)
      fn.set_named_args(arg_name_type)
      fn.node = node
      fn.body = node.children[2]
      scope_top.define(fn)
    end
  end
end

if __FILE__ == $0
  if ARGV.length < 1 then
    puts "Usage: ./turbocop.rb file1.rb file2.rb etc..."
  end

  got_errors = false
  ARGV.each do |filename|
    source = File.open(filename).read

    errors = Context.new(source).check
    if !errors.empty?
      got_errors = true
      puts errors.map{|e| Context.error_msg(filename, e)}.join("\n")
      puts "FAIL! #{filename}: #{errors.length} issues found."
    else
      puts "Pass! #{filename}"
    end
  end
  if got_errors then
    exit 1
  else
    exit 0
  end
end
