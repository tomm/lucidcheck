require_relative 'typechecks'

class FnSig
  attr_accessor :args, :optargs, :return_type, :kwargs

  def initialize(return_type, anon_args)
    @args = []
    @optargs = []
    @kwargs = {}
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

  #: fn(Hash<String, Rbindable>)
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
    names.each_index { |i| @args[i][0] = names[i] }
  end

  def name_optargs(names)
    names.each_index { |i| @optargs[i][0] = names[i] }
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
  def call_typecheck?(node, fn_name, passed_args_n_optargs, passed_kwargs, mut_template_types, block, self_type)

    errors = []

    function_call_type_error = ->() {
      [node, :fn_arg_type, fn_name,
       args_to_s(mut_template_types),
       passed_args_n_optargs.map(&:name).join(',')
      ]
    }
  
    check_passed_args = ->(accept_args, passed_args, can_default) {
      # type check arguments
      accept_args.zip(passed_args).each { |definition, passed|
        def_type = definition[1]
        passed = def_type if can_default && passed.nil?
        if def_type.is_a?(TemplateType)
          #template arg
          t = mut_template_types[def_type]
          if t.nil? || t.is_a?(TemplateType)
            if self_type.is_a?(Rconcreteclass)
              if self_type.specialize(def_type, passed) == false
                return [function_call_type_error.()]
              end
            end
            mut_template_types[def_type] = passed
          elsif !t.supertype_of?(passed)
            return [function_call_type_error.()]
          end
        else
          # normal arg
          if (def_type.is_a?(SelfType) && self_type.supertype_of?(passed)) ||
              (!def_type.is_a?(SelfType) && def_type.supertype_of?(passed))
            # type check passed
          else
            return [function_call_type_error.()]
          end
        end
      }
      []
    }

    if passed_args_n_optargs.length < @args.length || passed_args_n_optargs.length > @args.length + @optargs.length
      num_required =
        if @optargs.length > 0 then "#{@args.length}..#{@args.length + @optargs.length}"
        else @args.length end
      return [[node, :fn_arg_num, fn_name, num_required, passed_args_n_optargs.length]]
    end

    # type check kwargs
    kw_errors = TypeChecks.check_and_learn_kwargs(node, @kwargs, passed_kwargs)
    return kw_errors if !kw_errors.empty?

    # collect arg types if we know none
    if type_unknown?
      accept_args = @args.clone
      passed_args_n_optargs.take(accept_args.length).each_with_index { |a, i| accept_args[i][1] = a }
    else
      accept_args = @args
    end

    # if an optargs defaults to nil, learn what other type it can take
    passed_args_n_optargs.drop(accept_args.length).each_with_index { |a, i|
      # XXX should compare with @rnil...
      if @optargs[i][1].name == 'Nil'
        @optargs[i][1] = sum_of_types([ @optargs[i][1], a ])
      end
    }

    # type check mandatory arguments
    errors.concat(check_passed_args.(accept_args, passed_args_n_optargs, false))
    # type check optional arguments
    errors.concat(check_passed_args.(@optargs, passed_args_n_optargs.drop(accept_args.length), true))

    # success
    # set function signature to inferred types if inference happened
    if type_unknown?
      @args = accept_args
    end
    return errors
  end

  def args_to_s(template_types = {})
    (@args.map { |a| template_types[a[1]]&.name || a[1]&.name || 'unknown' } +
     @optargs.map { |a| template_types[a[1]]&.name || a[1]&.name || 'unknown' }.map { |n| '?' + n }
     #+ @kwargs.map { |kv| "#{kv[0]}: #{kv[1].name}" }
    )
      .join(',')
  end

  def sig_to_s(template_types = {})
    "(#{args_to_s(template_types)}) > #{(template_types[@return_type] || @return_type)&.name || 'unknown'}"
  end

  def to_s
    sig_to_s({})
  end
end

# just a function sig without the return type
class BuiltinSig < FnSig
  def initialize(arg_types)
    super(nil, arg_types)
  end
end
