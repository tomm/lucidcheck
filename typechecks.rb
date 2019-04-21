module TypeChecks
  # returns errors
  def self.check_and_learn_kwargs(node, definition, passed)
    errors = []
    outside = passed.keys.select { |k| !definition.include?(k) }
    if outside.length != 0
      errors << [node, :fn_kwargs_unexpected, outside]
    else
      passed.each { |kv|
        type = definition[kv[0]]
        # XXX dirty to use string comparison here. need ref to @rnil
        if type.name == 'Nil'
          # kwargs declared as nil will additionally bind to whatever
          # is first passed to them
          definition[kv[0]] = sum_of_types([type, kv[1]])
        elsif !type.supertype_of?(kv[1])
          errors << [node, :fn_kwarg_type, kv[0], type.name, kv[1].name]
        end
      }
    end
    errors
  end
end
