class Nil
end

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

class Float
  def +; end        #: unsafe fn(Float) -> Float
  def -; end        #: unsafe fn(Float) -> Float
  def *; end        #: unsafe fn(Float) -> Float
  def /; end        #: unsafe fn(Float) -> Float
  def >; end        #: unsafe fn(Float) -> Boolean
  def >=; end       #: unsafe fn(Float) -> Boolean
  def <; end        #: unsafe fn(Float) -> Boolean
  def <=; end       #: unsafe fn(Float) -> Boolean
  def ==; end       #: unsafe fn(Float) -> Boolean
end

class Boolean
  def ==; end       #: unsafe fn(Boolean) -> Boolean
end

class String
  def upcase; end   #: unsafe fn() -> String
  def slice; end    #: unsafe fn(Integer, ?Integer) -> String
  def split; end    #: unsafe fn(?String) -> Array<String>
  def +; end        #: unsafe fn(String) -> String
  def ==; end       #: unsafe fn(String) -> Boolean
  def length; end   #: unsafe fn() -> Integer
end

class File
  # XXX constructor wrong

  def self.open; end #: unsafe fn(String) -> File
  def read; end      #: unsafe fn() -> String
end

class Symbol
end

class Regexp
  def initialize; end #: unsafe fn(String)
  def match; end      #: unsafe fn(String | Symbol) -> MatchData | Nil
end

class MatchData
end

class Exception; end
class StandardError < Exception; end
class RuntimeError < StandardError; end

=begin
#: class<T>
class Array
  def initialize; end    #: unsafe fn() -> Array<T>
  def push; end          #: unsafe fn(T) -> Self
end
=end
