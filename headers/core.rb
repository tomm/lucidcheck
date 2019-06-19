class Integer
  def +; end        #: unsafe fn(Integer) -> Integer
  def -; end        #: unsafe fn(Integer) -> Integer
  def *; end        #: unsafe fn(Integer) -> Integer
  def /; end        #: unsafe fn(Integer) -> Integer
  def %; end        #: unsafe fn(Integer) -> Integer
  def >; end        #: unsafe fn(Integer) -> Boolean
  def >=; end       #: unsafe fn(Integer) -> Boolean
  def <; end        #: unsafe fn(Integer) -> Boolean
  def <=; end       #: unsafe fn(Integer) -> Boolean
  def ==; end       #: unsafe fn(Integer) -> Boolean
end

class String
  def upcase; end   #: unsafe fn() -> String
  def slice; end    #: unsafe fn(Integer, ?Integer) -> String
  def split; end    #: unsafe fn(?String) -> Array<String>
  def +; end        #: unsafe fn(String) -> String
  def ==; end       #: unsafe fn(String) -> Boolean
  def length; end   #: unsafe fn() -> Integer
end

class Symbol
end

class Regexp
  def initialize; end #: unsafe fn(String)
  def match; end      #: unsafe fn(String | Symbol) -> MatchData | Nil
end

class MatchData
end
