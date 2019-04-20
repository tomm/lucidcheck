class FnSig
  attr_accessor :args, :return_type, :kwargs

  def initialize(return_type, anon_args)
    @args = []
    @optargs = []
    @kwargs = nil
    @return_type = return_type
    add_anon_args(anon_args)
  end

  def no_args?
    @args.empty? && @optargs.empty? && @kwargs.empty?
  end

  #: fn(Array<Rbindable>)
  def add_anon_args(args)
    args.each { |a| @args << [nil, a] }
  end

  #: fn(Kwtype)
  def set_kwargs(kwargs)
    @kwargs = kwargs
  end

  #: fn(Array<Tuple<String, Rbindable>>)
  def add_opt_args(args)
    @optargs.concat(args)
  end

  # named as in def my_func(x, y, z). ie not keyword args
  #: fn(Array<Tuple<String, Rbindable>>)
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

  #: fn(FnSig, Hash<TemplateType, Rbindable>)
  def structural_eql?(other_sig, template_types = {})
    ret = template_types[@return_type] || @return_type
    args_match = other_sig.args.map { |v|
        template_types[v[1]] || v[1]
    } == @args.map{|v|v[1]}
    return (ret == other_sig.return_type) && args_match
  end

  ##: fn(Array[Rbindable]) > Array[error]
  def call_typecheck?(node, fn_name, passed_args, kwargs, mut_template_types, block, self_type)

    if passed_args.length != @args.length
      return [[node, :fn_arg_num, fn_name, @args.length, passed_args.length]]
    end

    if @kwargs != nil && kwargs != nil
      kw_errors = @kwargs.check_and_learn(node, kwargs)
      return kw_errors if !kw_errors.empty?
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
        elsif !t.supertype_of?(passed)
          return [function_call_type_error(node, fn_name, passed_args, mut_template_types)]
        end
      else
        # normal arg
        if (def_type.is_a?(SelfType) && self_type.supertype_of?(passed)) ||
            (!def_type.is_a?(SelfType) && def_type.supertype_of?(passed))
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

# just a function sig without the return type
class BuiltinSig < FnSig
  def initialize(arg_types)
    super(nil, arg_types)
  end
end
