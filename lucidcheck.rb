#!/usr/bin/env ruby
require 'pry'
require 'ripper'

# type annotation examples:
# String | Integer
# fn(Integer,String) -> String
# fn(fn() -> String)
# Array<Integer>
# [Integer, String, Boolean]
# fn<T>(T,T) -> T
# fn<T,U>(fn(T) -> U, Array<T>) -> Array<U>
class AnnotationParser
  class TokenizerError < RuntimeError; end

  def initialize(tokens, lookup)
    @tokens = tokens
    @lookup = lookup
  end

  def self.tokenize(str)
    tokens = []
    pos = 0
    identifier_regex = /^[A-Za-z]+[!\?]?/

    while pos < str.length do
      c = str.slice(pos)

      if c == " " || c == "\t"
        # eat whitespace
        pos += 1
      elsif c == "-" && str.slice(pos + 1) == '>'
        # return type
        tokens << '->'
        pos += 2
      elsif (m = identifier_regex.match(str.slice(pos, str.length)))
        # identifier
        tokens << m[0]
        pos += m[0].length
      else
        tokens << c
        pos += 1
      end
    end
    tokens
  end

  #: fn() -> [type, error?]
  def get_type
    type = parse_type
    raise TokenizerError, "malformed annotation" unless @tokens.empty?
    [type, nil]
  rescue TokenizerError => e
    [nil, e.to_s]
  end

  private

  def parse_type
    if has 'fn'
      eat
      expect! '('
      args = []
      loop {
        args.push(parse_type) if !has ')'
        if has(',') then eat else break end
      }
      expect! ')'
      if has '->'
        eat
        return_type = parse_type
      else
        return_type = @lookup.('Nil')[0]
      end

      Rfunc.new(nil, return_type, args)

    else
      @lookup.(eat)[0]
    end
  end

  def eat
    v = @tokens.first
    @tokens = @tokens.drop(1)
    v
  end

  def has(val)
    @tokens.first == val
  end

  def expect!(val)
    if !has(val)
      raise TokenizerError, "expected #{val} but found #{@tokens.first} in type annotation"
    else
      eat
    end
  end
end

class CheckerBug < RuntimeError
end

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
end

class FnScope < Scope
  attr_reader :passed_block, :is_constructor, :caller_node, :in_class
  #: fn(Rmetaclass | Rclass, Rblock | nil)
  def initialize(caller_node, fn_body_node, in_class, parent_scope, passed_block, is_constructor: false)
    @in_class = in_class
    @local_scope = {}
    @parent_scope = parent_scope
    @passed_block = passed_block
    @is_constructor = is_constructor
    @caller_node = caller_node
    @fn_body_node = fn_body_node
  end

  def is_fn_body_node_in_stack(node)
    @fn_body_node.equal?(node) || @parent_scope && @parent_scope.is_fn_body_node_in_stack(node)
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

class FnSig
  attr_accessor :args, :return_type

  def initialize(return_type, anon_args)
    @args = []
    @return_type = return_type
    add_anon_args(anon_args)
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

  def name_anon_args(names)
    names.each_index { |i|
      @args[i][0] = names[i]
    }
  end

  def type_unknown?
    @args.map{ |a| a[1] == nil }.any? || @return_type.kind_of?(Rundefined)
  end

  def get_specialized_args(template_types)
    @args.map{ |a| template_types[a[1]] || a[1] }
  end

  #: fn(FnSig)
  def structural_eql?(other_sig, template_types = {})
    ret = template_types[@return_type] || @return_type
    args_match = other_sig.args.map { |v|
        template_types[v[1]] || v[1]
    } == @args.map{|v|v[1]}
    return (ret == other_sig.return_type) && args_match
  end

  ##: fn(Array[Rbindable]) > Array[error]
  def call_typecheck?(node, fn_name, passed_args, mut_template_types, block, self_type)

    if passed_args.map { |a| a == nil }.any?
      raise CheckerBug.new("Passed nil arg to method #{fn_name}. weird. args: #{passed_args}")
      #return [[node, :fn_inference_fail, fn_name]]
    end

    if passed_args.length != @args.length
      return [[node, :fn_arg_num, fn_name, @args.length, passed_args.length]]
    end

    # collect arg types if we know none
    if type_unknown?
      accept_args = @args.clone
      passed_args.each_with_index { |a, i| accept_args[i][1] = a }
    else
      accept_args = @args
    end

    # type check arguments
    accept_args.zip(passed_args).each { |definition, passed|
      def_type = definition[1]
      if def_type.is_a?(TemplateType)
        #template arg
        t = mut_template_types[def_type]
        if t.nil? || t.is_a?(TemplateType)
          if self_type.is_a?(Rconcreteclass)
            if self_type.specialize(def_type, passed) == false
              return [function_call_type_error(node, fn_name, passed_args, mut_template_types)]
            end
          end
          mut_template_types[def_type] = passed
        elsif t != passed
          return [function_call_type_error(node, fn_name, passed_args, mut_template_types)]
        end
      else
        # normal arg
        if (def_type.is_a?(SelfType) && passed == self_type) ||
           (!def_type.is_a?(SelfType) && passed == def_type)
          # type check passed
        else
          return [function_call_type_error(node, fn_name, passed_args, mut_template_types)]
        end
      end
    }
    # success
    # set function signature to inferred types if inference happened
    if type_unknown?
      @args = accept_args
    end
    return []
  end

  def args_to_s(template_types = {})
    @args.map { |a| template_types[a[1]]&.name || a[1]&.name || '?' }.join(',')
  end

  def sig_to_s(template_types = {})
    "(#{args_to_s(template_types)}) > #{(template_types[@return_type] || @return_type)&.name || '?'}"
  end

  def to_s
    sig_to_s({})
  end

  private

  #: fn() > Array[error]
  def function_call_type_error(node, fn_name, passed_args, template_types)
    [node, :fn_arg_type, fn_name, args_to_s(template_types), passed_args.map(&:name).join(',')]
  end
end

class Rblock
  attr_reader :sig, :body_node, :fn_scope
  # fn(Array[String], node)
  def initialize(arg_names, body_node, fn_scope)
    @sig = FnSig.new(nil, [])
    @sig.add_named_args(arg_names.map { |name| [name, nil] })
    @fn_scope = fn_scope
    @body_node = body_node
  end
end

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
end

# when type inference fails
class Rundefined < Rbindable
  def initialize
    super(:undefined, nil)
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

  def add_template_params_scope(mut_template_types)
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
    @options = types
      .map { |t| if t.is_a?(Rsumtype) then t.options else [t] end }
      .flatten
      .uniq
      .sort_by { |a| a.name.to_s }
  end

  def lookup(name)
    [nil, nil]
  end

  def name
    @options.map(&:name).join(' | ')
  end

  def is_optional
    !!@options.detect { |o| o.name == 'Nil' }
  end

  def to_non_optional
    types = @options.reject { |o| o.name == 'Nil' }
    if types.length == 1
      types.first
    else
      Rsumtype.new(types)
    end
  end

  def ==(other)
    if other.is_a?(Rsumtype)
      other.options.map { |o| @options.include?(o) }.all?
    else
      @options.map { |o| o == other }.any?
    end
  end
end

def make_root
  robject = Rclass.new('Object', nil)

  _K = TemplateType.new
  _V = TemplateType.new
  _T = TemplateType.new
  _U = TemplateType.new
  # denny is right
  rstring  = robject.define(Rclass.new('String', robject))
  rsymbol  = robject.define(Rclass.new('Symbol', robject))
  rnil     = robject.define(Rclass.new('Nil', robject))
  rinteger = robject.define(Rclass.new('Integer', robject))
  rfloat   = robject.define(Rclass.new('Float', robject))
  rboolean = robject.define(Rclass.new('Boolean', robject))
  rarray   = robject.define(Rclass.new('Array', robject, template_params: [_T]))
  rhash    = robject.define(Rclass.new('Hash', robject, template_params: [_K, _V]))
  rrange   = robject.define(Rclass.new('Range', robject, template_params: [_T]))
  rfile    = robject.define(Rclass.new('File', robject))
  rexception = robject.define(Rclass.new('Exception', robject))
  rstandarderror = robject.define(Rclass.new('StandardError', rexception))
  rruntimeerror = robject.define(Rclass.new('RuntimeError', rstandarderror))
  rself    = robject.define(SelfType.new)

  robject.define(Rconst.new('ARGV', rarray[[rstring]]))
  robject.define(Rlvar.new('$0', rstring))
  robject.define(Rfunc.new('!', rboolean, []))
  robject.define(Rfunc.new('require', rnil, [rstring]))
  robject.define(Rfunc.new('puts', rnil, [rstring]))
  robject.define(Rfunc.new('p', _T, [_T]))
  robject.define(Rfunc.new('exit', rnil, [rinteger]))
  robject.define(Rfunc.new('rand', rfloat, []))
  robject.define(Rfunc.new('to_s', rstring, []))
  robject.define(Rfunc.new('to_f', rfloat, []))
  robject.define(Rfunc.new('to_i', rinteger, []))

  # XXX incomplete
  rfile.metaclass.define(Rfunc.new('open', rfile, [rstring]))
  rfile.define(Rfunc.new('read', rstring, []))

  rrange.define(Rfunc.new("to_a", rarray[[_T]], []))

  rhash.metaclass.define(Rfunc.new('new', rhash[[_K, _V]], []))
  rhash.define(Rfunc.new('[]=', _V, [_K, _V]))
  rhash.define(Rfunc.new('[]', _V, [_K]))

  rarray.metaclass.define(Rfunc.new('new', rarray[[_T]], []))
  rarray.define(Rfunc.new('length', rinteger, []))
  rarray.define(Rfunc.new('clear', rself, []))
  rarray.define(Rfunc.new('push', rself, [_T]))
  rarray.define(Rfunc.new('[]', _T, [rinteger]))
  rarray.define(Rfunc.new('[]=', _T, [rinteger, _T]))
  rarray.define(Rfunc.new('include?', rboolean, [_T]))
  # XXX incomplete
  rarray.define(Rfunc.new('join', rstring, [rstring]))
  rarray.define(Rfunc.new('empty?', rboolean, []))
  rarray.define(Rfunc.new('map', rarray[[_U]], [], block_sig: FnSig.new(_U, [_T])))
  rarray.define(Rfunc.new('each', rarray[[_T]], [], block_sig: FnSig.new(_U, [_T])))
  rarray.define(Rfunc.new('==', rboolean, [rself]))

  rstring.define(Rfunc.new('upcase', rstring, []))
  # XXX incomplete
  rstring.define(Rfunc.new('split', rarray[[rstring]], [rstring]))
  rstring.define(Rfunc.new('+', rstring, [rstring]))
  rstring.define(Rfunc.new('==', rboolean, [rstring]))

  rinteger.define(Rfunc.new('+', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('-', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('*', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('/', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('>', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('>=', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('<', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('<=', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('==', rboolean, [rinteger]))

  rfloat.define(Rfunc.new('+', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('-', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('*', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('/', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('>', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('>=', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('<', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('<=', rboolean, [rfloat]))

  rboolean.define(Rfunc.new('==', rboolean, [rboolean]))

  robject
end

class Context
  attr_reader :rself

  def object
    @robject
  end

  def self.error_msg(filename, e)
    "#{filename}:#{e[0]&.loc&.line}:#{e[0]&.loc&.column&.+ 1}: E: " +
      case e[1]
      when :invalid_safe_send
        "Use of '&.' operator on non-nullable type '#{e[2]}'"
      when :type_unknown
        "Type '#{e[2]}' not found in this scope"
      when :ivar_assign_outside_constructor
        "Instance variable assignment (of '#{e[2]}') outside the constructor is obfuscatory. Assignment ignored."
      when :fn_unknown
        "Type '#{e[3]}' has no method named '#{e[2]}'"
      when :const_unknown
        "Constant '#{e[2]}' not found in this scope"
      when :lvar_unknown
        "Local variable '#{e[2]}' not found in this scope"
      when :ivar_unknown
        "Instance variable '#{e[2]}' not found in this scope"
      when :gvar_unknown
        "Global variable '#{e[2]}' not found"
      when :expected_boolean
        "expected a boolean value, but #{e[2]} found"
      when :fn_inference_fail
        "Could not infer type of function '#{e[2]}'. Add a type annotation"
      when :fn_arg_num
        "Function '#{e[2]}' expected #{e[3]} arguments but found #{e[4]}"
      when :fn_arg_type
        "Function '#{e[2]}' arguments have inferred type (#{e[3]}) but is passed (#{e[4]})"
      when :fn_return_type
        "Function '#{e[2]}' has inferred return type '#{e[3]}', but returns '#{e[4]}'"
      when :block_arg_type
        "Function '#{e[2]}' takes a block of type '#{e[3]}' but is passed '#{e[4]}'"
      when :block_arg_num
        "Function '#{e[2]}' expected a block with #{e[3]} arguments, but passed block with #{e[4]} arguments"
      when :match_type
        "Expected '#{e[2]}' in when clause, but found '#{e[3]}"
      when :var_type
        "Cannot reassign variable '#{e[2]}' of type #{e[3]} with value of type #{e[4]}"
      when :array_mixed_types
        "Mixed types not permitted in array literal."
      when :hash_mixed_types
        "Mixed types not permitted in hash literal."
      when :inference_failed
        "Cannot infer type. Annotation needed."
      when :const_redef
        "Cannot redefine constant '#{e[2]}'"
      when :no_block_given
        "No block given"
      when :parse_error
        "Parse error: #{e[2]}"
      when :rescue_exception_type
        "Invalid exception type in 'rescue': #{e[2]}"
      when :annotation_error
        e[2]
      else
        e.to_s
      end
  end

  def initialize
    # '24' if RUBY_VERSION='2.4.4'
    #ruby_version = RUBY_VERSION.split('.').take(2).join
    #require "parser/ruby#{ruby_version}"
    
    require "parser/current"
    @robject = make_root()
    @rself = @robject.lookup(:genericSelf)[0]
    @rnil = @robject.lookup('Nil')[0]
    @rboolean = @robject.lookup('Boolean')[0]
    @rarray = @robject.lookup('Array')[0]
    @rhash = @robject.lookup('Hash')[0]
    @rrange = @robject.lookup('Range')[0]
    @rundefined = Rundefined.new

    @errors = []
    @annotations = {}
    @scopestack = [FnScope.new(nil, nil, @robject, nil, nil)]
  end

  def check(source)
    @errors.clear
    begin
      lines = source.split("\n")
      @annotations = (1..lines.length).to_a.zip(lines).select { |item|
        item[1].strip.slice(0, 3) == '#: '
      }.map { |i|
        annotation = i[1].strip.slice(3, i[1].length)  # strip '#: '
        tokens = AnnotationParser.tokenize(annotation)
        [i[0], tokens]
      }.to_h
      ast = Parser::CurrentRuby.parse(source)
    rescue StandardError => e
      # XXX todo - get line number
      @errors << [nil, :parse_error, e.to_s]
    else
      n_expr(ast)
      check_function_type_inference_succeeded(@robject)
    end
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

  def scope_top
    @scopestack.last
  end

  def pop_scope
    @scopestack.pop
  end

  #: fn(FnScope)
  def push_scope(fnscope)
    @scopestack.push(fnscope)
  end

  #: returns type
  def n_expr(node)
    case node&.type
    when nil
      @rnil
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
    when :self
      scope_top.in_class
    when :gvar
      gvar = @robject.lookup(node.children[0].to_s)[0]
      if gvar == nil
        @errors << [node, :gvar_unknown, node.children[0].to_s]
        @rundefined
      else
        gvar.type
      end
    when :ivar
      ivar = scope_top.lookup(node.children[0].to_s)[0]
      if ivar == nil
        @errors << [node, :ivar_unknown, node.children[0].to_s]
        @rundefined
      else
        ivar.type
      end
    when :lvar
      lvar = scope_top.lookup(node.children[0].to_s)[0]
      if lvar == nil
        @errors << [node, :lvar_unknown, node.children[0].to_s]
        @rundefined
      else
        lvar.type
      end
    when :and
      n_logic_op(node)
    when :or
      n_logic_op(node)
    when :send
      n_send(node)
    when :csend
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
      n_if(node)
    when :float
      lookup_type(@robject, 'Float')
    when :int
      lookup_type(@robject, 'Integer')
    when :str
      lookup_type(@robject, 'String')
    when :dstr # XXX could check dstr
      n_dstr(node)
    when :true
      lookup_type(@robject, 'Boolean')
    when :false
      lookup_type(@robject, 'Boolean')
    when :sym
      lookup_type(@robject, 'Symbol')
    when :array
      n_array_literal(node)
    when :hash
      n_hash_literal(node)
    when :yield
      n_yield(node)
    when :super
      n_super(node)
    when :zsuper
      n_zsuper(node)
    when :kwbegin
      n_kwbegin(node)
    when :rescue
      n_rescue(node)
    when :resbody
      n_resbody(node)
    when :ensure
      n_ensure(node)
    when :irange
      n_irange(node)
    when :case
      n_case(node)
    when :const
      c = scope_top.lookup(node.children[1].to_s)[0]
      if c
        c.type
      else
        @errors << [node, :const_unknown, node.children[1].to_s]
        @rundefined
      end
    else
      raise "Line #{node.loc.line}: unknown AST node type #{node.type}:\r\n#{node}"
    end
  end

  def n_dstr(node)
    if node.children.map { |n| n_expr(n).is_a?(Rundefined) }.any?
      @rundefined
    else
      lookup_type(@robject, 'String')
    end
  end

  def n_case(node)
    needle = n_expr(node.children[0])
    whens = node.children.drop(1)
      .take_while { |n| n&.type == :when }
      .map { |n|
        _case_type = n_expr(n.children[0])
        if _case_type != needle
          @errors << [n.children[0], :match_type, needle.to_s, _case_type.to_s]
        end
        n_expr(n.children[1])
      }
    # catch-all (else)
    whens << n_expr(node.children.last)
    whens.uniq!

    if whens.length == 1
      whens.first
    else
      Rsumtype.new(whens)
    end
  end

  def n_irange(node)
    _from = n_expr(node.children[0])
    _to = n_expr(node.children[1])
    int = lookup_type(@robject, 'Integer')

    if _from != int || _to != int
      @errors << [node, :fn_arg_type, 'range', 'Integer,Integer', "#{_from.name},#{_to.name}"]
      @rundefined
    else
      @rrange[[int]]
    end
  end

  def n_resbody(node)
    _exceptions = node.children[0].to_a.map{ |n|
      type = n_expr(n)
      if type.is_a?(Rmetaclass)
        type.metaclass_for
      else
        @errors << [n, :rescue_exception_type, type.name]
        nil
      end
    }.compact

    p node.children[1]
    if node.children[1] != nil
      # assign exception to an lvar
      raise CheckerBug, 'expected lvasgn in resbody' unless node.children[1].type == :lvasgn
      name = node.children[1].children[0].to_s
      type = case _exceptions.length
             when 0
               @robject.lookup('StandardError')[0]
             when 1
               _exceptions.first
             else
               Rsumtype.new(_exceptions)
             end
      puts "assigning #{type.name} to #{name}"
      rbinding, _ = scope_top.lookup(name)

      if type.is_a?(Rundefined)
        # error already reported. do nothing
      elsif rbinding == nil
        scope_top.define_lvar(Rlvar.new(name, type))
      elsif rbinding.type != type
        @errors << [node, :var_type, name, rbinding.type.name, type.name]
      end
    end
    n_expr(node.children[2])
  end

  def n_kwbegin(node)
    raise CheckerBug, "too many kwbegin children" unless node.children.length == 1
    n_expr(node.children[0])
  end

  def n_ensure(node)
    _rescue = n_expr(node.children[0])
    _ensure = n_expr(node.children[1])
    _rescue
  end

  def n_rescue(node)
    _begin = n_expr(node.children[0])
    _resbody = n_expr(node.children[1])
    _else = n_expr(node.children[2])

    if _else == @rnil
      if _resbody == _begin
        _resbody
      else
        Rsumtype.new([_resbody, _begin])
      end
    else
      if _resbody == _else
        _resbody
      else
        Rsumtype.new([_resbody, _else])
      end
    end
  end

  #: fn(&fn() -> Rbindable)
  def weak_scoped
    push_scope(WeakScope.new(scope_top))
    v = yield
    pop_scope()
    v
  end

  def n_if(node)
    weak_scoped {
      cond = n_expr(node.children[0])
      type1 = weak_scoped { n_expr(node.children[1]) }
      type2 = weak_scoped { n_expr(node.children[2]) }

      if cond != @rboolean
        @errors << [node, :expected_boolean, cond.name]
      end
      if type1 == type2
        type1
      else
        Rsumtype.new([type1, type2])
      end
    }
  end

  def n_logic_op(node)
    left = n_expr(node.children[0])
    right = n_expr(node.children[1])
    if left != @rboolean
      @errors << [node.children[0], :expected_boolean, left.name]
    end
    if right != @rboolean
      @errors << [node.children[1], :expected_boolean, right.name]
    end
    @rboolean
  end

  def block_call(node, block, passed_args, mut_template_types)
    if block == nil
      @errors << [scope_top.caller_node || node, :no_block_given]
      @rundefined
    else
      type_errors = block.sig.call_typecheck?(scope_top.caller_node || node, '<block>', passed_args, mut_template_types, nil, scope_top.in_class)

      if !type_errors.empty?
        @errors.concat(type_errors)
        return @rundefined
      end

      function_scope = FnScope.new(node, block.body_node, scope_top.in_class, block.fn_scope, nil)
      # define lvars from arguments
      block.sig.args.each { |a| function_scope.define_lvar(Rlvar.new(a[0], a[1])) }

      # find block return type by evaluating body with concrete argument types in scope
      push_scope(function_scope)
      block.sig.return_type = n_expr(block.body_node)
      pop_scope()

      block.sig.return_type
    end
  end

  def n_yield(node)
    args = node.children.map {|n| n_expr(n) }
    block = scope_top.passed_block
    block_call(node, block, args, {})
  end

  def n_super(node)
    args = node.children.map {|n| n_expr(n) }
    fn, call_scope = scope_top.lookup_super
    function_call(scope_top.in_class, call_scope, fn, node, args, scope_top.passed_block)
  end

  def n_zsuper(node)
    fn, call_scope = scope_top.lookup_super
    function_call(scope_top.in_class, call_scope, fn, node, [], scope_top.passed_block)
  end

  def n_hash_literal(node)
    if node.children == nil || node.children.length == 0
      @rhash.new_generic_specialization
    else
      contents = node.children.map {|n| [n_expr(n.children[0]),
                                         n_expr(n.children[1])] }

      fst_type = contents.first
      if contents.map {|v| v == fst_type }.all?
        @rhash[fst_type]
      else
        @errors << [node, :hash_mixed_types]
        @rundefined
      end
    end
  end

  def n_array_literal(node)
    if node.children == nil || node.children.length == 0
      @rarray.new_generic_specialization
    else
      contents = node.children.map {|n| n_expr(n) }

      fst_type = contents.first
      if contents.map {|v| v == fst_type }.all?
        @rarray[[fst_type]]
      else
        @errors << [node, :array_mixed_types]
        @rundefined
      end
    end
  end

  def n_class(node)
    class_name = node.children[0].children[1].to_s
    parent_class_name = node.children[1]&.children&.last&.to_s
    parent_class = parent_class_name == nil ? @robject : scope_top.lookup(parent_class_name)[0]

    new_class = Rclass.new(
      class_name,
      parent_class
    )

    scope_top.in_class.define(new_class)

    push_scope(FnScope.new(node, nil, new_class, nil, nil, is_constructor: false))
    r = n_expr(node.children[2])

    # define a 'new' static method if 'initialize' was not defined
    if scope_top.in_class.metaclass.lookup('new')[0] == nil
      scope_top.in_class.metaclass.define(Rfunc.new('new', new_class))
    end

    pop_scope()

    r
  end

  def lookup_type(scope, type_identifier)
    type = scope.lookup(type_identifier)[0]
    if type == nil then
      # type not found
      @errors << [node, :type_unknown, type_identifier]
      @rundefined
    else
      type
    end
  end

  # assign instance variable
  def n_ivasgn(node)
    name = node.children[0].to_s
    type = n_expr(node.children[1])

    if type.is_a?(Rundefined)
      # error already reported. do nothing
    elsif scope_top.lookup(name)[0] == nil
      if scope_top.is_constructor == false
        @errors << [node, :ivar_assign_outside_constructor, name]
      else
        scope_top.define_ivar(Rlvar.new(name, type))
      end
    elsif scope_top.lookup(name)[0].type != type
      @errors << [node, :var_type, name, scope_top.lookup(name)[0].type.name, type.name]
    else
      # binding already existed. types match. cool
    end
    
    type
  end

  def n_lvasgn(node)
    name = node.children[0].to_s
    type = n_expr(node.children[1])

    rbinding, _ = scope_top.lookup(name)

    if type.is_a?(Rundefined)
      # error already reported. do nothing
    elsif rbinding == nil
      scope_top.define_lvar(Rlvar.new(name, type))
    elsif rbinding.type != type
      @errors << [node, :var_type, name, rbinding.type.name, type.name]
    end

    type
  end

  def n_casgn(node)
    name = node.children[1].to_s
    type = n_expr(node.children[2])

    if type == nil
      # error already reported. do nothing
    elsif scope_top.lookup(name)[0] == nil
      scope_top.define_ivar(Rconst.new(name, type))
    else
      @errors << [node, :const_redef, name]
    end

    type
  end

  def n_block(node)
    send_node = node.children[0]
    block_arg_names = node.children[1].children.to_a.map { |v| v.children[0].to_s }
    block_body = node.children[2]

    raise CheckerBug.new("expected :send, found #{send_node.type} in :block") unless send_node.type == :send

    n_send(send_node, block = Rblock.new(block_arg_names, block_body, scope_top))
  end

  # returns return type of method/function (or nil if not determined)
  def n_send(node, block=nil)
    name = node.children[1].to_s
    type_scope = node.children[0] ? n_expr(node.children[0]) : scope_top.in_class
    name = node.children[1].to_s
    arg_types = node.children[2..-1].map {|n| n_expr(n) }

    return @rundefined if type_scope.kind_of?(Rundefined)

    # &. method invocation
    if node.type == :csend
      if type_scope.is_a?(Rsumtype) && type_scope.is_optional
        type_scope = type_scope.to_non_optional
      else
        @errors << [node, :invalid_safe_send, type_scope.name]
        return @rundefined
      end
    end

    # find actual class the method was retrieved from. eg may be parent class of 'type_scope'
    fn, call_scope = type_scope.lookup(name)

    if fn == nil
      @errors << [node, :fn_unknown, name, type_scope.name]
      @rundefined
    elsif !fn.kind_of?(Rfunc)
      @errors << [node, :not_a_function, name]
      @rundefined
    else
      ret = function_call(type_scope, call_scope, fn, node, arg_types, block)

      if node.type == :csend
        Rsumtype.new([@rnil, ret])
      else
        ret
      end
    end
  end

  # in the example of '1.2'.to_f:
  # type_scope = String
  # call_scope = Object (because to_f is on Object)
  # fn = RFunc of whatever Object.method(:to_f) is
  def function_call(type_scope, call_scope, fn, node, args, block)
    if fn.is_constructor
      if !call_scope.is_a?(Rmetaclass)
        raise CheckerBug, 'constructor not called with scope of metaclass'
      end
      call_scope = call_scope.metaclass_for
    end
    template_types = { @rself => type_scope }
    type_scope.add_template_params_scope(template_types)
    type_errors = fn.sig.call_typecheck?(node, fn.name, args, template_types, block, type_scope)

    if !type_errors.empty?
      @errors.concat(type_errors)
    elsif fn.block_sig && block.nil?
      @errors << [scope_top.caller_node || node, :no_block_given]
    elsif fn.block_sig && block.sig.args.length != fn.block_sig.args.length
      @errors << [scope_top.caller_node || node, :block_arg_num, fn.name, fn.block_sig.args.length, block.sig.args.length]
    elsif fn.body != nil # means not a purely 'header' function def (ie ruby standard lib type stubs)
      function_scope = FnScope.new(node, fn.body, call_scope, nil, block, is_constructor: fn.is_constructor)
      # define lvars from arguments
      fn.sig.args.each { |a| function_scope.define_lvar(Rlvar.new(a[0], a[1])) }

      if scope_top.is_fn_body_node_in_stack(fn.body)
        # never actually recurse! we want this bastible to finish
        if fn.return_type == nil
          fn.return_type = Rrecursion.new
        end
      else
        # find function return type by evaluating body with concrete argument types in scope
        push_scope(function_scope)
        ret = n_expr(fn.body)
        if !fn.is_constructor
          if fn.return_type == nil
            fn.return_type = ret
          elsif fn.return_type != ret && !fn.return_type.is_a?(Rundefined)
            @errors << [node, :fn_return_type, fn.name, fn.return_type.name, ret.name]
          end
        end
        pop_scope()
      end

      if block
        if fn.block_sig && !fn.block_sig.structural_eql?(block.sig, template_types)
          # block type mismatch
          @errors << [scope_top.caller_node || node, :block_arg_type, fn.name, fn.block_sig.sig_to_s(template_types), block.sig.sig_to_s(template_types)]
        else
          fn.block_sig = block.sig
        end
      end
    else
      # purely 'header' function def. resolve template types
      if block && fn.block_sig
        block_args = fn.block_sig.get_specialized_args(template_types)
        block_ret = block_call(node, block, block_args, template_types)
        expected_ret = to_concrete_type(fn.block_sig.return_type, type_scope, template_types)

        if expected_ret.is_a?(TemplateType)
          # discover template return type
          if type_scope.is_a?(Rconcreteclass)
            type_scope.specialize(expected_ret, block_ret)
          end
          template_types[expected_ret] = block_ret
        elsif expected_ret != block_ret
          # block return type mismatch
          @errors << [node, :block_arg_type, fn.name, fn.block_sig.sig_to_s(template_types), block.sig.sig_to_s(template_types)]
        end
      end
    end

    # fn.return_type can be nil if type inference has not happened yet
    # XXX but how can that still be the case here?
    to_concrete_type(fn.return_type || @rundefined, type_scope, template_types)
  end

  def to_concrete_type(type, self_type, template_types)
    if self_type.is_a?(Rconcreteclass) && self_type.specialization[type]
      # a generic type param of the self type
      self_type.specialization[type]
    elsif type.is_a?(SelfType)
      self_type
    elsif type.is_a?(TemplateType)
      (template_types[type] || type)
    else
      t = type
      if t.is_a?(Rconcreteclass)
        t = t.new_inst
        template_types.each_pair { |k,v| t.new_inst_specialize(k, v) }
      end
      t
    end
  end

  def get_annotation_for_node(node)
    if (annot = @annotations[node.loc.line-1])
      type, error = AnnotationParser.new(annot, scope_top.method(:lookup)).get_type
      @errors << [node, :annotation_error, error] unless error == nil
      type
    else
      nil
    end
  end

  # define static method
  def n_defs(node)
    if node.children[0].type != :self
      raise "Checker bug. Expected self at #{node}"
    end
    name = node.children[1].to_s
    # [ [name, type], ... ]
    arg_name_type = node.children[2].to_a.map{|x| [x.children[0].to_s, nil] }

    annot_type = get_annotation_for_node(node)
    if annot_type
      fn = annot_type
      fn.name = name
      if arg_name_type.length != fn.sig.args.length
        @errors << [node, :annotation_error, "Number of arguments (#{arg_name_type.length}) does not match annotation (#{fn.sig.args.length})"]
      else
        fn.sig.name_anon_args(arg_name_type.map { |nt| nt[0] })
      end
    else
      # don't know types of arguments or return type yet
      fn = Rfunc.new(name, @rundefined)
      fn.add_named_args(arg_name_type)
    end
    fn.node = node
    fn.body = node.children[3]
    if fn.body == nil then fn.return_type = @rnil end
    scope_top.in_class.metaclass.define(fn)
  end

  def n_def(node)
    name = node.children[0].to_s
    # [ [name, type], ... ]
    arg_name_type = node.children[1].to_a.map{|x| [x.children[0].to_s, nil] }

    annot_type = get_annotation_for_node(node)

    # define function with no known argument types (so far)
    if name == 'initialize'
      if annot_type
        @errors << [node, :annotation_error, "Annotations not (yet) supported on constructors"]
      end
      # assume return type for 'new' method
      fn = Rfunc.new('new', scope_top.in_class, is_constructor: true)
      fn.add_named_args(arg_name_type)
      fn.node = node
      fn.body = node.children[2]
      scope_top.in_class.metaclass.define(fn)
    else
      if annot_type
        fn = annot_type
        fn.name = name
        if arg_name_type.length != annot_type.sig.args.length
          @errors << [node, :annotation_error, "Number of arguments (#{arg_name_type.length}) does not match annotation (#{annot_type.sig.args.length})"]
        else
          fn.sig.name_anon_args(arg_name_type.map { |nt| nt[0] })
        end
      else
        # don't know types of arguments or return type yet
        fn = Rfunc.new(name, nil)
        fn.add_named_args(arg_name_type)
      end
      fn.node = node
      fn.body = node.children[2]
      # can assume return type of nil if body is empty
      if fn.body == nil then fn.return_type = @rnil end
      scope_top.in_class.define(fn)
    end
  end
end

if __FILE__ == $0
  if ARGV.length < 1 then
    puts "Usage: lucidcheck file1.rb file2.rb etc..."
  end

  if ARGV == ['--version']
    puts "0.1.0"
    exit 0
  end

  got_errors = false
  ARGV.each do |filename|
    source = File.open(filename).read

    errors = Context.new.check(source)
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
