require 'pry'
require_relative 'scopes'
require_relative 'rbindable'
require_relative 'fnsig'
require_relative 'annotations'
require_relative 'types_core'

class Context
  attr_reader :rself

  def object
    @robject
  end

  def filename_of_node(node)
    @node_filename_map[node]
  end

  def error(e)
    @errors << e if !scope_top.silent
  end

  def error_msg(e)
    filename = filename_of_node(e[0])
    "#{filename}:#{e[0]&.loc&.line}:#{e[0]&.loc&.column&.+ 1}: E: " +
      case e[1]
      when :invalid_safe_send
        "Use of '&.' operator on non-nullable type '#{e[2]}'"
      when :type_unknown
        "Type '#{e[2]}' not found in this scope"
      when :ivar_assign_outside_constructor
        "Instance variable declaration (of '#{e[2]}') outside the constructor is obfuscatory. Assignment ignored."
      when :fn_unknown
        "Type '#{e[3]}' has no method named '#{e[2]}'"
      when :const_unknown
        "Constant '#{e[2]}' not found in scope '#{e[3]}'"
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
      when :tuple_too_big
        "Tuple with too many values. Maximum is #{@rtuple.max_template_params}"
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
      when :require_error
        e[2]
      when :annotation_mismatch
        "Type is annotated as #{e[2]}, but found #{e[3]}"
      when :annotation_error
        e[2]
      when :checker_bug
        e[2]
      when :tuple_index
        "Invalid tuple index for type '#{e[2]}'"
      when :masgn_rhs_type
        "Multiple assignment requires a tuple on the righthand side, but found '#{e[2]}'"
      when :masgn_length_mismatch
        "Number of variables to assign does not match tuple length (found #{e[3]}, need #{e[2]})"
      when :general_type_error
        "Expected '#{e[2]}' but found '#{e[3]}'"
      when :fn_kwargs_unexpected
        "Unexpected keyword arguments: #{e[2].join(', ')}"
      when :fn_kwarg_type
        "Keyword argument '#{e[2]}' expected type '#{e[3]}' but found '#{e[4]}'"
      when :unmatched_override
        "Can not override method '#{e[2]}' of type '#{e[3]}' with '#{e[4]}'"
      when :fn_redef
        "Can not redefine method '#{e[2]}'"
      else
        e.to_s
      end
  end

  # check_all=false does not alter the overall type checking algorithm,
  # it just suppresses error reporting in un-annotated code sections
  def initialize(check_all: true)
    # '24' if RUBY_VERSION='2.4.4'
    #ruby_version = RUBY_VERSION.split('.').take(2).join
    #require "parser/ruby#{ruby_version}"
    
    require "parser/current"
    @robject = make_robject()
    @rself = @robject.lookup(:genericSelf)[0]
    @rnil = @robject.lookup('Nil')[0].metaclass_for
    @rboolean = @robject.lookup('Boolean')[0].metaclass_for
    @rstring = @robject.lookup('String')[0].metaclass_for
    @rinteger = @robject.lookup('Integer')[0].metaclass_for
    @rarray = @robject.lookup('Array')[0].metaclass_for
    @rtuple = @robject.lookup('Tuple')[0].metaclass_for
    @rhash = @robject.lookup('Hash')[0].metaclass_for
    @rrange = @robject.lookup('Range')[0].metaclass_for
    @rundefined = Rundefined.new

    define_builtins

    @errors = []
    @annotations = {}
    @required = []
    @node_filename_map = {}
    #: Array<Scope>
    @scopestack = []
    push_scope(FnScope.new(nil, nil, nil, @robject, nil, nil, !check_all))

    _check('core', File.open(__dir__ + '/headers/core.rb').read)

    @rsymbol = @robject.lookup('Symbol')[0].metaclass_for
  end

  def check(filename, source)
    @errors.clear
    _check(filename, source)
    check_function_type_inference_succeeded(@robject)
    @errors
  end

  private

  def _check(filename, source)
    begin
      lines = source.split("\n")
      @annotations[filename] = (1..lines.length).to_a.zip(lines).select { |item|
        item[1].strip.slice(0, 3) == '#: '
      }.map { |i|
        annotation = i[1].strip.slice(3, i[1].length)  # strip '#: '
        tokens = AnnotationParser.tokenize(annotation)
        [i[0], tokens]
      }.to_h
      ast = Parser::CurrentRuby.parse(source)
    rescue StandardError => e
      # XXX todo - get line number
      error [nil, :parse_error, e.to_s]
    else
      _build_node_filename_map(filename, ast)
      n_expr(ast)
    end
  end

  #: fn(Parser::AST::Node, String)
  def define_attr_reader(node, scope, name)
    # don't know what ivars are declared yet, so generate 'code'
    fn = Rfunc.new(name, nil, [], checked: false)
    fn.node = node
    fn.body = Parser::AST::Node.new(
      :ivar,
      [("@" + name).to_sym],
      { location: node.location }
    )

    # add generated code to node filename map, otherwise we 
    # can't report on errors in this code
    _build_node_filename_map(
      filename_of_node(node), fn.body
    )

    scope.define(fn)
  end

  #: fn(Parser::AST::Node, String)
  def define_attr_writer(node, scope, name)
    # don't know what ivars are declared yet, so generate 'code'
    fn = Rfunc.new(name + "=", nil, checked: false)
    fn.add_named_args([['v', nil]])
    fn.node = node
    fn.body = Parser::AST::Node.new(
      :begin,
      [
        Parser::AST::Node.new(
          :ivasgn,
          [
            ("@" + name).to_sym,
            Parser::AST::Node.new(:lvar, [:v])
          ],
          { location: node.location }
        ),
        Parser::AST::Node.new(
          :ivar,
          [("@" + name).to_sym],
          { location: node.location }
        )
      ],
      { location: node.location }
    )

    # add generated code to node filename map, otherwise we 
    # can't report on errors in this code
    _build_node_filename_map(
      filename_of_node(node), fn.body
    )

    scope.define(fn)
  end

  # parse ast node of 'attr_reader', 'attr_writer', 'attr_accessor'
  def parse_attr_builtin(node, rself, args, handler)
    args.each { |a|
      t = n_expr(a)
      if !@rsymbol.supertype_of?(t)
        error [node, :general_type_error, @rsymbol.name, t.name]
      else
        name = a.children[0].to_s
        handler.(a, name)
      end
    }
    @rnil
  end

  def define_builtins
    @robject.define(Rbuiltin.new('attr_reader', nil, ->(node, rself, args) {
      parse_attr_builtin(node, rself, args, ->(node, name) {
        define_attr_reader(node, rself, name)
      })
    }))

    @robject.define(Rbuiltin.new('attr_writer', nil, ->(node, rself, args) {
      parse_attr_builtin(node, rself, args, ->(node, name) {
        define_attr_writer(node, rself, name)
      })
    }))

    @robject.define(Rbuiltin.new('attr_accessor', nil, ->(node, rself, args) {
      parse_attr_builtin(node, rself, args, ->(node, name) {
        define_attr_reader(node, rself, name)
        define_attr_writer(node, rself, name)
      })
    }))

    @robject.define(Rbuiltin.new('require', BuiltinSig.new([@rstring]), method(:do_require)))
    @robject.define(Rbuiltin.new('require_relative', BuiltinSig.new([@rstring]), method(:do_require_relative)))

    @rtuple.define(Rbuiltin.new('[]', BuiltinSig.new([@rinteger]), ->(node, rself, args) {
      index = args[0].children[0]
      type = rself.specialization[ rself.template_class.template_params[index] ]
      if type == nil
        error [args[0], :tuple_index, rself.name]
        @rundefined
      else
        type
      end
    }))

    @rtuple.define(Rbuiltin.new('[]=', nil, ->(node, rself, args) {
      index = args[0].children[0]
      val = n_expr(args[1])
      if !index.is_a?(Integer)
        error [args[0], :tuple_index, rself.name]
        @rundefined
      else
        type = rself.specialization[ rself.template_class.template_params[index] ]
        if type == nil
          error [args[0], :tuple_index, rself.name]
          @rundefined
        elsif !type.supertype_of?(val)
          error [args[1], :fn_arg_type, '[]=', "Integer,#{type.name}", "Integer,#{val.name}"]
          @rundefined
        else
          type
        end
      end
    }))
  end

  def _build_node_filename_map(filename, node)
    @node_filename_map[node] = filename
    if node.methods.include?(:children) && node.children != nil
      node.children.each { |n| _build_node_filename_map(filename, n) if n != nil }
    end
  end

  class Rblock
    attr_reader :body_node, :fn_scope, :definition_only
    attr_accessor :sig
    # fn(Array[String], node)
    def initialize(arg_names, body_node, fn_scope, definition_only: false)
      @sig = FnSig.new(nil, [])
      @sig.add_named_args(arg_names.map { |name| [name, nil] })
      @fn_scope = fn_scope
      @body_node = body_node
      @definition_only = definition_only
    end
  end

  def do_require(node, rself, args, relative: false)
    if relative == false
      error [args.first, :require_error, "Absolute require not implemented (yet ;)"]
      @rundefined
    elsif args[0].type != :str
      error [args.first, :require_error, "Require can only take a string literal"]
      @rundefined
    else
      path = args[0].children[0]
      path += '.rb' if !path.end_with?('.rb')
      # already done!
      return @rboolean if @required.include?(path)
      puts "Following require '#{path}'"
      begin
        source = File.open(path).read
      rescue => e
        error [args.first, :require_error, e.to_s]
        @rundefined
      else
        @required << path
        _check(path, source)
        @rboolean
      end
    end
  end

  def do_require_relative(node, rself, args)
    do_require(node, rself, args, relative: true)
  end

  def check_function_type_inference_succeeded(scope)
    process = ->(scope, thing) {
      if thing.is_a?(Rlazydeffunc)
        thing = define_lazydeffunc(thing)
      end

      if thing.kind_of?(Rfunc)
        # never checked this function. if there is a type annotation
        # then we can check based on that
        if thing.checked == false && thing.can_autocheck
          call_by_definition_types(thing.node, scope, thing)
        end

        if thing.type_unknown?
          error [thing.node, :fn_inference_fail, thing.name]
        end
      elsif thing.kind_of?(Rmetaclass)
        check_function_type_inference_succeeded(thing.metaclass_for)
      end
    }
    if scope.is_a?(Rclass)
      constructor = scope.metaclass.lookup('new')[0]
      if constructor != nil
        process.(scope.metaclass, constructor)
      end
    end
    scope.metaclass.scope.each_value { |bindable|
      process.(scope.metaclass, bindable)
    }
    scope.scope.each_value { |bindable|
      process.(scope, bindable)
    }
  end

  def scope_top
    @scopestack.last
  end

  def pop_scope
    @scopestack.pop
  end

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
        error [node, :gvar_unknown, node.children[0].to_s]
        @rundefined
      else
        gvar
      end
    when :ivar
      ivar = scope_top.lookup(node.children[0].to_s)[0]
      if ivar == nil
        error [node, :ivar_unknown, node.children[0].to_s]
        @rundefined
      else
        ivar
      end
    when :lvar
      lvar = scope_top.lookup(node.children[0].to_s)[0]
      if lvar == nil
        error [node, :lvar_unknown, node.children[0].to_s]
        @rundefined
      else
        lvar
      end
    when :and
      n_logic_op(node)
    when :or
      n_logic_op(node)
    when :send
      n_send(node)
    when :csend
      n_send(node)
    when :masgn
      n_masgn(node)
    when :ivasgn
      n_ivasgn(node)
    when :lvasgn
      n_lvasgn(node)
    when :casgn
      n_casgn(node)
    when :class
      n_class(node)
    when :module
      n_module(node)
    when :if
      n_if(node)
    when :while
      n_while(node)
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
    when :return
      scope_top.add_return_val(n_expr(node.children[0]))
      Rretvoid.new
    when :const
      n_const(node)
    when :cbase
      @robject.metaclass
    else
      error [node, :checker_bug, "Lucidcheck Bug! This construct (#{node.type}) is not known"]
      puts "BUG! #{filename_of_node(node)}, line #{node.loc.line}: unknown AST node type #{node.type}:\r\n#{node}"
      @rundefined
    end
  end
  
  def n_masgn(node)
    lhs_node = node.children[0]
    rhs = read_rhs_type(node, node.children[1])
    raise "expected mlhs" if lhs_node.type != :mlhs
    if !rhs.is_specialization_of?(@rtuple)
      error [node, :masgn_rhs_type, rhs.name]
      @rundefined
    elsif lhs_node.children.length != rhs.specialization.length
      error [node, :masgn_length_mismatch, rhs.specialization.length, lhs_node.children.length]
      @rundefined
    else
      for index in 0...(rhs.specialization.length) do
        name = lhs_node.children[index].children[0].to_s
        type = rhs.specialization[ rhs.template_class.template_params[index] ]
        assign_type = lhs_node.children[index].type
        case assign_type
        when :lvasgn
          lvasgn(lhs_node.children[index], name, type)
        when :ivasgn
          ivasgn(lhs_node.children[index], name, type)
        else 
          error [node, :checker_bug, "Unexpected in masgn: #{assign_type}"]
        end
      end
      rhs
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
          error [n.children[0], :match_type, needle.name, _case_type.name]
        end
        n_expr(n.children[1])
      }
    # catch-all (else)
    whens << n_expr(node.children.last)
    sum_of_types(whens)
  end

  def n_irange(node)
    _from = n_expr(node.children[0])
    _to = n_expr(node.children[1])
    int = lookup_type(@robject, 'Integer')

    if _from != int || _to != int
      error [node, :fn_arg_type, 'range', 'Integer,Integer', "#{_from.name},#{_to.name}"]
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
        error [n, :rescue_exception_type, type.name]
        nil
      end
    }.compact

    if node.children[1] != nil
      # assign exception to an lvar
      raise 'expected lvasgn in resbody' unless node.children[1].type == :lvasgn
      name = node.children[1].children[0].to_s
      type = if _exceptions.length == 0
               @robject.lookup('StandardError')[0]&.metaclass_for
             else
               sum_of_types(_exceptions)
             end
      rbinding, _ = scope_top.lookup(name)

      if type.is_a?(Rundefined)
        # error already reported. do nothing
      elsif rbinding == nil
        scope_top.define_lvar(name, type)
      elsif rbinding != type
        error [node, :var_type, name, rbinding.name, type.name]
      end
    end
    n_expr(node.children[2])
  end

  def n_kwbegin(node)
    raise "too many kwbegin children" unless node.children.length == 1
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
        sum_of_types([_resbody, _begin])
      end
    else
      if _resbody == _else
        _resbody
      else
        sum_of_types([_resbody, _else])
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

  def n_while(node)
    # XXX need to implement break
    weak_scoped {
      cond = n_expr(node.children[0])
      body = n_expr(node.children[1])

      if cond != @rboolean
        error [node, :expected_boolean, cond.name]
      end
    }
    puts "Warning: n_while implementation incomplete"
    @rundefined
  end

  def n_if(node)
    weak_scoped {
      cond = n_expr(node.children[0])
      type1 = weak_scoped { n_expr(node.children[1]) }
      type2 = weak_scoped { n_expr(node.children[2]) }

      if cond != @rboolean
        error [node, :expected_boolean, cond.name]
      end

      sum_of_types([type1, type2])
    }
  end

  def n_logic_op(node)
    left = n_expr(node.children[0])
    right = n_expr(node.children[1])

    # no sensible checks, since this is a total shit-show operator
    sum_of_types([left, right])
  end

  def block_call(node, block, passed_args, mut_template_types)
    if block == nil
      error [scope_top.caller_node || node, :no_block_given]
      @rundefined
    else
      type_errors = block.sig.call_typecheck?(scope_top.caller_node || node, '<block>', passed_args, {}, mut_template_types, nil, scope_top.in_class)

      if !type_errors.empty?
        type_errors.each { |e| error e }
        return @rundefined
      end

      if !block.definition_only
        function_scope = FnScope.new(node, scope_top, block.body_node, scope_top.in_class, block.fn_scope, nil, scope_top.silent)
        # define lvars from arguments
        block.sig.args.each { |a| function_scope.define_lvar(a[0], a[1]) }

        # find block return type by evaluating body with concrete argument types in scope
        push_scope(function_scope)
        block.sig.return_type = n_expr(block.body_node)
        pop_scope()
      end

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
    function_call(scope_top.in_class, call_scope, fn, node, args, {}, scope_top.passed_block)
  end

  def n_zsuper(node)
    fn, call_scope = scope_top.lookup_super
    function_call(scope_top.in_class, call_scope, fn, node, [], {}, scope_top.passed_block)
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
        error [node, :hash_mixed_types]
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
      elsif contents.length <= @rtuple.max_template_params
        @rtuple[contents]
      else
        # XXX bad error messsage. maybe something about tuple length
        error [node, :tuple_too_big]
        @rundefined
      end
    end
  end

  def n_module(node)
    module_name = node.children[0].children[1].to_s

    new_module = Rmodule.new(module_name)

    scope_top.in_class.define(new_module)

    push_scope(FnScope.new(node, nil, nil, new_module, nil, nil, scope_top.silent, is_constructor: false))
    r = n_expr(node.children[1])
    pop_scope()

    r
  end

  def n_class(node)
    class_name = node.children[0].children[1].to_s
    parent_class_name = node.children[1]&.children&.last&.to_s
    parent_class = parent_class_name == nil ? @robject : scope_top.lookup(parent_class_name)[0]&.metaclass_for

    new_class = Rclass.new(
      class_name,
      parent_class
    )

    scope_top.in_class.define(new_class.metaclass, bind_to: class_name)

    push_scope(FnScope.new(node, nil, nil, new_class, nil, nil, scope_top.silent, is_constructor: false))
    r = n_expr(node.children[2])

    # define a 'new' static method if 'initialize' was not defined
    if scope_top.in_class.metaclass.lookup('new')[0] == nil
      scope_top.in_class.metaclass.define(Rfunc.new('new', new_class, checked: false))
    end

    pop_scope()

    r
  end

  def lookup_type(scope, type_identifier)
    type = scope.lookup(type_identifier)[0]
    if type == nil then
      # type not found
      error [node, :type_unknown, type_identifier]
      @rundefined
    else
      type.metaclass_for
    end
  end

  # assign instance variable
  def n_ivasgn(node)
    name = node.children[0].to_s
    type = read_rhs_type(node, node.children[1])
    ivasgn(node, name, type)
  end

  def ivasgn(node, name, type)
    if type.is_a?(Rundefined)
      # error already reported. do nothing
    elsif scope_top.lookup(name)[0] == nil
      if scope_top.is_constructor == false
        error [node, :ivar_assign_outside_constructor, name]
      else
        scope_top.define_ivar(name, type)
      end
    elsif !scope_top.lookup(name)[0].supertype_of?(type)
      error [node, :var_type, name, scope_top.lookup(name)[0].name, type.name]
    else
      # binding already existed. types match. cool
    end
    
    type
  end

  def read_rhs_type(annotation_node, rhs_node)
    annot_type = get_annotation_for_node(annotation_node)
    if annot_type&.unsafe
      annot_type
    else
      type = n_expr(rhs_node)
      if annot_type != nil
        if annot_type.is_a?(Rconcreteclass) && 
            type.is_a?(Rconcreteclass) &&
            type.is_fully_unspecialized? && 
            type.template_class == annot_type.template_class then
          # they are specializations of the same class, but 'type'
          # is not specialized yet. take specialization from annotation. 
        elsif !annot_type.supertype_of?(type)
          error [annotation_node, :annotation_mismatch, annot_type.name, type.name]
        end
        annot_type
      else
        type
      end
    end
  end

  def n_lvasgn(node)
    name = node.children[0].to_s
    type = read_rhs_type(node, node.children[1])
    lvasgn(node, name, type)
  end

  def lvasgn(node, name, type)
    rbinding, _ = scope_top.lookup(name)

    if type.is_a?(Rundefined)
      # error already reported. do nothing
    elsif rbinding == nil
      scope_top.define_lvar(name, type)
    elsif !rbinding.supertype_of?(type)
      error [node, :var_type, name, rbinding.name, type.name]
    end

    type
  end

  def n_casgn(node)
    name = node.children[1].to_s
    type = read_rhs_type(node, node.children[2])

    if type == nil
      # error already reported. do nothing
    elsif scope_top.lookup(name)[0] == nil
      scope_top.define_ivar(name, type)
    else
      error [node, :const_redef, name]
    end

    type
  end

  # const lookup
  def n_const(node)
    name = node.children[1].to_s
    scope = n_expr(node.children[0])
    if scope == @rnil
      scope = scope_top.in_class
    elsif scope.is_a?(Rmetaclass)
      scope = scope.metaclass_for
    elsif scope.is_a?(Rmodule)
      # good
    else
      error [node, :general_type_error, 'Class / Module', scope&.name]
      return @rundefined
    end
    c = scope.lookup(name)[0]
    if c != nil
      c
    else
      error [node, :const_unknown, name, scope.name]
      @rundefined
    end
  end

  def n_block(node)
    send_node = node.children[0]
    block_arg_names = node.children[1].children.to_a.map { |v| v.children[0].to_s }
    block_body = node.children[2]

    raise "expected :send, found #{send_node.type} in :block" unless send_node.type == :send

    n_send(send_node, block = Rblock.new(block_arg_names, block_body, scope_top))
  end

  # returns return type of method/function (or nil if not determined)
  def n_send(node, block=nil)
    name = node.children[1].to_s
    type_scope = node.children[0] ? n_expr(node.children[0]) : scope_top.in_class
    name = node.children[1].to_s
    arg_nodes = node.children[2..-1]
    arg_types = arg_nodes.select { |n| n.type != :hash }.map {|n| n_expr(n) }
    kw_arg_node = arg_nodes.find { |n| n.type == :hash }
    
    kwargs = if kw_arg_node.nil? then {} else n_kwargs(kw_arg_node) end

    return @rundefined if type_scope.kind_of?(Rundefined)

    # &. method invocation
    if node.type == :csend
      if type_scope.is_a?(Rsumtype) && type_scope.is_optional
        type_scope = type_scope.to_non_optional
      else
        error [node, :invalid_safe_send, type_scope.name]
        return @rundefined
      end
    end

    # find actual class the method was retrieved from. eg may be parent class of 'type_scope'
    fn, call_scope = type_scope.lookup(name)

    if fn.is_a?(Rlazydeffunc) then fn = define_lazydeffunc(fn) end

    if fn == nil
      error [node, :fn_unknown, name, type_scope.name]
      @rundefined
    elsif fn.kind_of?(Rbuiltin)
      errs = fn.sig.nil? ? [] : fn.sig.call_typecheck?(node, fn.name, arg_types, {}, {}, nil, type_scope)
      if errs.empty?
        fn.call(node, type_scope, arg_nodes)
      else
        errs.each { |e| error e }
        @rundefined
      end
    elsif fn.kind_of?(Rfunc)
      ret = function_call(type_scope, call_scope, fn, node, arg_types, kwargs, block)

      if node.type == :csend
        sum_of_types([@rnil, ret])
      else
        ret
      end
    else
      error [node, :not_a_function, name]
      @rundefined
    end
  end

  # in the example of '1.2'.to_f:
  # type_scope = String
  # call_scope = Object (because to_f is on Object)
  # fn = RFunc of whatever Object.method(:to_f) is
  def function_call(type_scope, call_scope, fn, node, args, kwargs, block)
    if fn.is_a?(Rlazydeffunc) then fn = define_lazydeffunc(fn) end

    if fn.is_constructor
      if !call_scope.is_a?(Rmetaclass)
        raise 'constructor not called with scope of metaclass'
      end
      call_scope = call_scope.metaclass_for
    end
    template_types = { @rself => type_scope }
    type_scope.add_template_params_scope(template_types)
    type_errors = fn.sig.call_typecheck?(node, fn.name, args, kwargs, template_types, block, type_scope)

    if !type_errors.empty?
      type_errors.each { |e| error e }
      return @rundefined
    elsif fn.block_sig && block.nil?
      error [scope_top.caller_node || node, :no_block_given]
      return @rundefined
    elsif fn.block_sig && block.sig.args.length != fn.block_sig.args.length
      error [scope_top.caller_node || node, :block_arg_num, fn.name, fn.block_sig.args.length, block.sig.args.length]
      return @rundefined
    elsif fn.body != nil
      # function definition with function body code
      function_scope = FnScope.new(node, scope_top, fn.body, call_scope, nil, block, scope_top.silent && fn.silent, is_constructor: fn.is_constructor)
      # define lvars from normal arguments
      fn.sig.args.each { |a|
        function_scope.define_lvar(
          a[0], template_types[a[1]] || a[1]
        )
      }
      # define lvars from normal arguments
      fn.sig.optargs.each { |a|
        function_scope.define_lvar(
          a[0], template_types[a[1]] || a[1]
        )
      }
      # define lvars from kwargs
      if fn.sig.kwargs != nil
        fn.sig.kwargs.each { |kv|
          function_scope.define_lvar(kv[0], kv[1])
        }
      end

      if scope_top.is_identical_fn_call_in_stack?(fn.body, block)
        # never actually recurse! we want this bastible to finish
        if fn.return_type == nil
          fn.return_type = Rrecursion.new
        end
      else
        # find function return type by evaluating body with concrete argument types in scope
        push_scope(function_scope)
        ret = sum_of_types([n_expr(fn.body), function_scope.return_vals], fn_ret: true)
        if !fn.is_constructor
          if fn.return_type == nil
            fn.return_type = ret
          elsif !fn.return_type.supertype_of?(ret) && !fn.return_type.is_a?(Rundefined)
            error [node, :fn_return_type, fn.name, fn.return_type.name, ret.name]
          end
        end
        pop_scope()
      end

      if block
        if fn.block_sig && !fn.block_sig.structural_eql?(block.sig, template_types)
          # block type mismatch
          error [scope_top.caller_node || node, :block_arg_type, fn.name, fn.block_sig.sig_to_s(template_types), block.sig.sig_to_s(template_types)]
        else
          fn.block_sig = block.sig
        end
      end

      fn.checked = true
    else
      # purely 'header' function def. (has type stub but no code).
      # resolve template types
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
          error [node, :block_arg_type, fn.name, fn.block_sig.sig_to_s(template_types), block.sig.sig_to_s(template_types)]
        end
      end
    end

    raise "wtf (#{fn.name})" if fn.return_type == nil

    # fn.return_type can be nil if type inference has not happened yet
    # XXX but how can that still be the case here?
    to_concrete_type(fn.return_type, type_scope, template_types)
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
    if (annot = @annotations[filename_of_node(node)][node.loc.line-1])
      type, e = AnnotationParser.new(annot, scope_top.method(:lookup)).get_type
      error [node, :annotation_error, e] unless e == nil
      type
    else
      nil
    end
  end

  def parse_function_args_def(args_node)
    all_args = args_node.to_a
    arg_name_type = all_args
      .select { |a| a.type == :arg }
      .map{ |a| [a.children[0].to_s, nil] }
    optarg_name_type = all_args
      .select { |a| a.type == :optarg }
      .map { |a| [a.children[0].to_s, n_expr(a.children[1])] }
    kwarg_name_type = all_args
      .select { |a| a.type == :kwoptarg }
      .map { |a| [a.children[0].to_s, n_expr(a.children[1])] }

    unknown_args = all_args.map(&:type).select { |t| ![:arg, :optarg, :kwoptarg].include?(t) }

    if unknown_args.length > 0
      error [args_node, :checker_bug, "Unknown argument types: #{unknown_args.join(', ')}"]
    end

    [arg_name_type, optarg_name_type, kwarg_name_type]
  end

  #: fn(Parser::AST::Node, String, Parser::AST::Node, Parser::AST::Node, Rclass) -> Rfunc
  def make_method(node, name, args_node, fn_body)
    arg_name_type, optarg_name_type, kwarg_name_type = parse_function_args_def(args_node)
    annot_type = get_annotation_for_node(node)

    if annot_type
      fn = annot_type
      fn.name = name
      # annotated functions show errors :)
      fn.silent = false
      # XXX update for kwarg nums!! XXX
      if arg_name_type.length != annot_type.sig.args.length
        error [node, :annotation_error, "Number of arguments (#{arg_name_type.length}) does not match annotation (#{annot_type.sig.args.length})"]
      elsif optarg_name_type.length != annot_type.sig.optargs.length
        error [node, :annotation_error, "Number of optional arguments (#{optarg_name_type.length}) does not match annotation (#{annot_type.sig.optargs.length})"]
      else
        fn.sig.name_anon_args(arg_name_type.map { |nt| nt[0] })
        fn.sig.name_optargs(optarg_name_type.map { |nt| nt[0] })
      end
    else
      # don't know types of arguments or return type yet
      fn = Rfunc.new(name, nil, checked: false)
      fn.add_named_args(arg_name_type)
      fn.set_kwargs(kwarg_name_type.to_h)
      fn.add_opt_args(optarg_name_type)
    end
    fn.node = node

    if !fn.unsafe
      fn.body = fn_body
      # can assume return type of nil if body is empty
      if fn.body == nil then fn.return_type = @rnil end
    end
    fn
  end

  def try_deffun(node, class_or_module, fn)
    existing_fn, existing_class = class_or_module.lookup(fn.name)
    if existing_fn != nil && existing_class.equal?(class_or_module)
      error [node, :fn_redef, fn.name]
    else
      class_or_module.define(fn)
    end
  end

  def n_def(node)
    name = node.children[0].to_s

    if name == 'initialize'
      try_deffun(node, scope_top.in_class.metaclass,
        Rlazydeffunc.new('new', node, scope_top.in_class.metaclass, ->(node, scope) {
          fn = make_method(node, 'new', node.children[1], node.children[2])
          fn.is_constructor = true
          if fn.sig.no_args?
            fn.can_autocheck = true
          end
          # XXX note that return type of possible annotation is ignored
          fn.return_type = scope.metaclass_for
          fn
        })
      )
    else
      try_deffun(
        node,
        scope_top.in_class,
        Rlazydeffunc.new(name, node, scope_top.in_class, ->(node, scope) {
          make_method(node, name, node.children[1], node.children[2])
        })
      )
      #end
    end
  end
  
  def try_override(_class, fn)
    return true if fn.name == 'new'
    return true if _class.is_a?(Rmodule)
    return true if _class.parent.nil?

    parent_fn, parent_scope = _class.parent.lookup(fn.name)

    if parent_fn.is_a?(Rlazydeffunc)
      parent_fn = define_lazydeffunc(parent_fn)
    end

    if parent_fn.nil? || fn.sig.structural_eql?(parent_fn.sig)
      true
    else
      error [fn.node, :unmatched_override, fn.name, parent_fn.sig.sig_to_s({}), fn.sig.sig_to_s({})]
      false
    end
  end

  #: fn(Rlazydeffunc) -> Rfunc
  def define_lazydeffunc(lazydef)
    name = lazydef.name
    class_or_module = lazydef.class_or_module
    fn = lazydef.build()

    if try_override(class_or_module, fn)
      class_or_module.define(fn)
    end

    fn
  end

  # define static method
  def n_defs(node)
    if node.children[0].type != :self
      raise "Checker bug. Expected self at #{node}"
    end
    name = node.children[1].to_s
    try_deffun(
      node,
      scope_top.in_class.metaclass,
      Rlazydeffunc.new(name, node, scope_top.in_class.metaclass, ->(node, scope) {
        make_method(node, name, node.children[2], node.children[3])
      })
    )
  end

  # type check based on annotated types, rather than types passed in code
  def call_by_definition_types(node, rclass, fn)
    type_scope = rclass
    call_scope = rclass
    fn_scope = [FnScope.new(nil, nil, nil, @robject, nil, nil, scope_top.silent)]
    arg_types = fn.sig.args.map { |a| a[1] }
    block = Rblock.new([], nil, fn_scope, definition_only: true)
    block.sig = fn.block_sig
    kwargs = fn.sig.kwargs.clone

    function_call(type_scope, call_scope, fn, fn.body, arg_types, kwargs, block)
  end

  #: fn(Parser::AST::Node) -> Hash<String, Rbindable>
  def n_kwargs(node)
    raise "not kwargs" unless node.type == :hash

    node.children.map {|n| [n.children[0].children[0].to_s,
                            n_expr(n.children[1])] }.to_h
  end
end
