#!/usr/bin/env ruby
require './lucidcheck'
require 'test/unit'

def node_to_line_nums(errors)
  errors.map { |es| [[es[0].loc.line], es[1..-1]].flatten }
end

def parse_str(str)
  node_to_line_nums(Context.new(str).check)
end

def parse_file(filename)
  parse_str(File.open(filename).read)
end

class TestLucidCheck < Test::Unit::TestCase
  def test_reassign
    assert_equal(
      [[3, :var_type, :x, 'Integer', 'Boolean']],
      parse_str(
        <<-RUBY
          x = 123
          x = 234
          x = true
        RUBY
      )
    )
  end

  def test_num_args_and_type_inf
    assert_equal(
      [[1, :fn_unknown, :hi, 'Object'],
       [5, :fn_arg_num, :hi, 1, 2],
       [7, :fn_arg_type, :hi, 'String', 'Integer']],
      parse_str(
        <<-RUBY
          hi('bob') # fails
          def hi(name)
            puts "num #{name}"
          end
          hi('tom', 'thing') # fails
          hi('joe')
          hi(123) # fails
        RUBY
      )
    )
  end

  def test_consts
    assert_equal(
      [[2, :const_redef, :MyConst],
       [4, :var_type, :x, 'Integer', 'String']],
      parse_str(
        <<-RUBY
          MyConst = 123
          MyConst = 234
          x = MyConst
          x = 'poo'
        RUBY
      )
    )
  end

  def test_method_type_inference
    assert_equal(
      [[4, :fn_arg_num, :returns_int, 0, 1],
       [6, :var_type, :z, 'Integer', 'Boolean']],
      parse_str(
        <<-RUBY
          def returns_int
            123
          end
          z = returns_int(2) # fails
          z = returns_int()
          z = true # fails

          def returns_int2
            returns_int
          end
          z = returns_int2
        RUBY
      )
    )
  end

  def test_methods
    assert_equal(
      [[1, :fn_unknown, :upcase, 'Object'],
       [6, :fn_unknown, :upcase, 'Integer']],
      parse_str(
        <<-RUBY
          upcase
          a = "hi"
          b = a.upcase
          b.upcase
          c = 12
          c.upcase
        RUBY
      )
    )
  end
end
