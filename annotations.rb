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

  def parse_block_sig
    expect! '&'
    expect! '('
    args = []
    loop {
      args.push(parse_type) if !has ')'
      break unless has ','
    }
    expect! ')'
    return_type = if has '->'
      eat
      parse_type
    else
      @lookup.('Nil')[0]
    end
    FnSig.new(return_type, args)
  end

  def parse_type
    if has 'fn'
      eat
      has '('
      args = []
      block_sig = nil
      loop {
        eat
        if has '&'
          block_sig = parse_block_sig
          break
        elsif !has ')'
          args.push(parse_type)
        end

        break unless has ','
      }
      expect! ')'
      if has '->'
        eat
        return_type = parse_type
      else
        return_type = @lookup.('Nil')[0]
      end

      t = Rfunc.new(nil, return_type, args, block_sig: block_sig)
      puts "making turd #{t.sig.to_s}"
      t
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
