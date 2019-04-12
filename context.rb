require 'pry'
require './annotations'
require './scopes'
require './fnsig'
require './rbindable'
require './types_core'

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
    @robject = make_robject()
    @rself = @robject.lookup(:genericSelf)[0]
    @rnil = @robject.lookup('Nil')[0]
    @rboolean = @robject.lookup('Boolean')[0]
    @rarray = @robject.lookup('Array')[0]
    @rhash = @robject.lookup('Hash')[0]
    @rrange = @robject.lookup('Range')[0]
    @rundefined = Rundefined.new

    @errors = []
    @annotations = {}
    @scopestack = [FnScope.new(nil, nil, nil, @robject, nil, nil)]
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
    when :return
      scope_top.add_return_val(n_expr(node.children[0]))
      Rretvoid.new
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
    sum_of_types(whens)
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
      raise 'expected lvasgn in resbody' unless node.children[1].type == :lvasgn
      name = node.children[1].children[0].to_s
      type = if _exceptions.length == 0
               @robject.lookup('StandardError')[0]
             else
               sum_of_types(_exceptions)
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

  def n_if(node)
    weak_scoped {
      cond = n_expr(node.children[0])
      type1 = weak_scoped { n_expr(node.children[1]) }
      type2 = weak_scoped { n_expr(node.children[2]) }

      if cond != @rboolean
        @errors << [node, :expected_boolean, cond.name]
      end

      sum_of_types([type1, type2])
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

      function_scope = FnScope.new(node, scope_top, block.body_node, scope_top.in_class, block.fn_scope, nil)
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

    push_scope(FnScope.new(node, nil, nil, new_class, nil, nil, is_constructor: false))
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

    raise "expected :send, found #{send_node.type} in :block" unless send_node.type == :send

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
        sum_of_types([@rnil, ret])
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
        raise 'constructor not called with scope of metaclass'
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
      function_scope = FnScope.new(node, scope_top, fn.body, call_scope, nil, block, is_constructor: fn.is_constructor)
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
        ret = sum_of_types([n_expr(fn.body), function_scope.return_vals], fn_ret: true)
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