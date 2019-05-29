#:: lucidcheck
class Symbol
end

class Regexp
  #: unsafe fn(String)
  def initialize(s); end
  #: unsafe fn(String | Symbol) -> MatchData | Nil
  def match(s); end
end

class MatchData
end

=begin
class Integer
  #: unsafe fn(Integer) -> Integer
  def +; end
end
=end
