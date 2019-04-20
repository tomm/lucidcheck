require_relative 'rbindable'

class Kwtype
  attr_reader :map

  #: fn(Hash<String, Rbindable>)
  def initialize(map)
    @map = map
  end

  def empty?
    @map.empty?
  end

  # returns errors
  #: fn(Hash<String, Rbindable>) -> Array<String>
  def check_and_learn(node, other)
    raise "kwtype::check_and_learn expected Kwtype" unless other.is_a?(Kwtype)
    errors = []
    outside = other.map.keys.select { |k| !@map.include?(k) }
    if outside.length != 0
      errors << [node, :fn_kwargs_unexpected, outside]
    else
      other.map.each { |kv|
        type = @map[kv[0]]
        # XXX dirty to use string comparison here. need ref to @rnil
        if type.name == 'Nil'
          # kwargs declared as nil will additionally bind to whatever
          # is first passed to them
          @map[kv[0]] = sum_of_types([type, kv[1]])
        elsif !type.supertype_of?(kv[1])
          errors << [node, :fn_kwarg_type, kv[0], type.name, kv[1].name]
        end
      }
    end
    errors
  end
end
