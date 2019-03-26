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

class CheckerBug < RuntimeError
end

class FnScope
  attr_reader :passed_block
  #: fn(Rmetaclass | Rclass, Rblock | nil)
  def initialize(in_class, parent_scope, passed_block)
    @in_class = in_class
    @local_scope = {}
    @parent_scope = parent_scope
    @passed_block = passed_block
  end

  def lookup(name)
    o = @local_scope[name] || @parent_scope&.lookup(name)
    if o then o else @in_class.lookup(name) end
  end

  def define(rscopebinding)
    @local_scope[rscopebinding.name] = rscopebinding
  end
end

class FnSig
  attr_accessor :args, :return_type

  def initialize
    @args = []
    @return_type = nil
  end

  #: fn(Array[Rbindable])
  def add_anon_args(args)
    args.each { |a| @args << [nil, a] }
  end

  # named as in def my_func(x, y, z). ie not keyword args
  #: fn(Array[[String, Rbindable]])
  def add_named_args(args)
    @args.concat(args)
  end

  def type_unknown?
    @args.map{ |a| a[1] == nil }.any? || @return_type.kind_of?(Rundefined)
  end

  #: fn(FnSig)
  def structural_eql?(other_sig)
    (@return_type == other_sig.return_type) && (other_sig.args.map{|v|v[1]} == @args.map{|v|v[1]})
  end

  #: fn(Array[Rbindable]) > Array[error]
  def call_typecheck?(node, fn_name, passed_args, block)
    if passed_args.map { |a| a == nil }.any?
      raise CheckerBug.new("Passed nil arg to method #{fn_name}. weird. args: #{passed_args}")
      #return [[node, :fn_inference_fail, fn_name]]
    end

    if passed_args.length != @args.length
      return [[node, :fn_arg_num, fn_name, @args.length, passed_args.length]]
    end

    # collect arg types if we know none
    if type_unknown?
      passed_args.each_with_index { |a, i| @args[i][1] = a }
    end

    # type check arguments
    if @args.map {|a| a[1]} != passed_args
      [function_call_type_error(node, fn_name, passed_args)]
    else
      []
    end
  end

  def args_to_s
    @args.map { |a| a[1]&.name || '?' }.join(',')
  end

  def to_s
    "(#{args_to_s}) > #{@return_type&.name || '?'}"
  end

  private

  #: fn() > Array[error]
  def function_call_type_error(node, fn_name, passed_args)
    [node, :fn_arg_type, fn_name, args_to_s, passed_args.map(&:name).join(',')]
  end
end

class Rblock
  attr_reader :sig, :body_node
  # fn(Array[String], node)
  def initialize(arg_names, body_node)
    @sig = FnSig.new
    @sig.add_named_args(arg_names.map { |name| [name, nil] })
    @body_node = body_node
  end
end

# Something you can assign to a variable
class Rbindable
  attr_reader :name, :type
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
end

# when type inference fails
class Rundefined < Rbindable
  def initialize
    super(:undefined, nil)
  end
end

class Rlvar < Rbindable
end

class Rconst < Rbindable
end

class Rfunc < Rbindable
  attr_accessor :node, :body, :sig, :block_sig

  #: fn(String, Rbindable, Array[Rbindable])
  def initialize(name, return_type, anon_args = [])
    super(name, nil)
    @sig = FnSig.new
    @sig.add_anon_args(anon_args)
    @sig.return_type = return_type
    @block_sig = nil
    @node = nil
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

class Rclass < Rbindable
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

class Rsumtype < Rbindable
  attr_reader :options
  #: fn(Array[Rbindable])
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
  robject.define(Rfunc.new('to_s', rstring, []))

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
        "Could not infer type of function '#{e[2]}'. Add a type annotation (not yet supported ;)"
      when :fn_arg_num
        "Function '#{e[2]}' expected #{e[3]} arguments but found #{e[4]}"
      when :fn_arg_type
        "Function '#{e[2]}' arguments have inferred type (#{e[3]}) but is passed (#{e[4]})"
      when :block_arg_type
        "Function '#{e[2]}' takes a block of type '#{e[3]}' but is passed '#{e[4]}'"
      when :block_arg_num
        "Function '#{e[2]}' expected a block with #{e[3]} arguments, but passed block with #{e[4]} arguments"
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
    @callstack = [FnScope.new(@robject, nil, nil)]
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
    when :block
      n_block(node)
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
    when :yield
      n_yield(node)
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

  def n_yield(node)
    args = node.children.map {|n| n_expr(n) }
    block = callstack_top.passed_block
    type_errors = block.sig.call_typecheck?(node, '<block>', args, nil)

    if !type_errors.empty?
      @errors.concat(type_errors)
      return @rundefined
    end

    function_scope = FnScope.new(scope_top, callstack_top, nil)
    # define lvars from arguments
    block.sig.args.each { |a| function_scope.define(Rlvar.new(a[0], a[1])) }

    # find block return type by evaluating body with concrete argument types in scope
    push_callstack(function_scope)
    block.sig.return_type = n_expr(block.body_node)
    pop_callstack()

    block.sig.return_type
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

  def n_block(node)
    send_node = node.children[0]
    block_arg_names = node.children[1].children.to_a.map { |v| v.children[0].to_s }
    block_body = node.children[2]

    raise CheckerBug.new("expected :send, found #{send_node.type} in :block") unless send_node.type == :send

    n_send(send_node, block = Rblock.new(block_arg_names, block_body))
  end

  # returns return type of method/function (or nil if not determined)
  def n_send(node, block=nil)
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
    raise CheckerBug, 'invalid nil scope' if scope.nil?
    name = node.children[1].to_s
    arg_types = node.children[2..-1].map {|n| n_expr(n) }
    num_args = arg_types.length

    if scope.lookup(name) == nil
      @errors << [node, :fn_unknown, name, scope.name]
      return @rundefined
    elsif scope.lookup(name).kind_of?(Rfunc)
      return_type, errors = function_call(scope, scope.lookup(name), node, arg_types, block)
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
  # updates @fn_sig with param types if nil
  def function_call(scope, fn, node, args, block)
    type_errors = fn.sig.call_typecheck?(node, fn.name, args, block)

    if !type_errors.empty?
      return [fn.return_type, type_errors]
    end

    if fn.block_sig && block.sig.args.length != fn.block_sig.args.length
      return [fn.return_type, [[node, :block_arg_num, fn.name, fn.block_sig.args.length, block.sig.args.length]]]
    end

    if fn.body != nil # means not a purely 'header' function def (ie ruby standard lib type stubs)
      function_scope = FnScope.new(scope, callstack_top, block)
      # define lvars from arguments
      fn.sig.args.each { |a| function_scope.define(Rlvar.new(a[0], a[1])) }

      # find function return type by evaluating body with concrete argument types in scope
      push_callstack(function_scope)
      fn.return_type = n_expr(fn.body)
      pop_callstack()

      if block
        if fn.block_sig && !fn.block_sig.structural_eql?(block.sig)
          # block type mismatch
          return [fn.return_type, [[node, :block_arg_type, fn.name, fn.block_sig.to_s, block.sig.to_s]]]
        else
          fn.block_sig = block.sig
        end
      end
    end

    [fn.return_type, []]
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
    fn.add_named_args(arg_name_type)
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
      fn.add_named_args(arg_name_type)
      fn.node = node
      fn.body = node.children[2]
      scope_top.metaclass.define(fn)
    else
      # don't know types of arguments or return type yet
      fn = Rfunc.new(name, @rundefined)
      fn.add_named_args(arg_name_type)
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
