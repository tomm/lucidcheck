#!/usr/bin/env ruby
require './lucidcheck'
require 'test/unit'

def node_to_line_nums(errors)
  errors.map { |es| [[es[0]&.loc&.line], es[1..-1]].flatten }
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
      [[3, :var_type, 'x', 'Integer', 'Boolean']],
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
      [[1, :fn_unknown, 'hi', 'Object'],
       [5, :fn_arg_num, 'hi', 1, 2],
       [7, :fn_arg_type, 'hi', 'String', 'Integer']],
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
      [[2, :const_redef, 'MyConst'],
       [4, :var_type, 'x', 'Integer', 'String'],
       [5, :const_unknown, 'Huh'],
       [6, :const_unknown, 'What']],
      parse_str(
        <<-RUBY
          MyConst = 123
          MyConst = 234
          x = MyConst
          x = 'poo'
          Huh
          z = What.new
        RUBY
      )
    )
  end

  def test_method_type_inference
    assert_equal(
      [[4, :fn_arg_num, 'returns_int', 0, 1],
       [6, :var_type, 'z', 'Integer', 'Boolean']],
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
      [[1, :fn_unknown, 'upcase', 'Object'],
       [6, :fn_unknown, 'upcase', 'Integer']],
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

  def test_class
    assert_equal(
      [[24, :fn_unknown, 'wrong', 'B'],
       [25, :var_type, 'b', 'B', 'Integer'],
       [29, :fn_unknown, 'oi', 'A']],
      parse_str(
        <<-RUBY
          class A
            def initialize(title)
            end

            def hi(name)
              puts "hey #{name}"
            end
          end
          
          class B < A
            def oi(name)
              puts "oi #{name}"
            end

            def self.foo(x, y)
              x + y
            end
          end

          B.foo(1,2)
          b = B.new
          b.oi('tom')
          b.hi('bob')
          b.wrong()
          b = 12

          a = A.new('Ms')
          a.hi('sam')
          a.oi('emma')
        RUBY
      )
    )
  end

  def test_arithmetic
    assert_equal(
      [[3, :fn_arg_type, '*', 'Float', 'Integer'],
       [5, :fn_arg_type, '/', 'Integer', 'Float']],
      parse_str(
        <<-RUBY
          x = 1 + 1
          y = 2 * x
          z = 4.0 * y
          z = (4.0 + x.to_f) * y.to_f
          y = y / z
        RUBY
      )
    )
  end

  def test_function_type_inference
    assert_equal(
      [[8, :var_type, 'a', 'Float', 'Integer'],
       [9, :fn_arg_type, 'thing', 'Float,Integer', 'Integer,Float'],
       [12, :fn_inference_fail, 'never_called']],
      parse_str(
        <<-RUBY
          def thing(x, y)
            x * y.to_f
          end
          def other_thing(z)
            thing(z, 3) * z
          end
          a = thing(1.0, 2)
          a = 3
          b = thing(1, 2.0)
          a = other_thing(3.0)

          def never_called(u, v)
            u + v
          end
        RUBY
      )
    )
  end

  def test_method_type_inference2
    assert_equal(
      [[11, :var_type, 'u', 'String', 'Integer'],
       [5, :fn_inference_fail, 'never_called']],
      parse_str(
        <<-RUBY
          class A
            def gets_called(x)
              x
            end
            def never_called(y)
              y
            end
          end
          a = A.new
          u = a.gets_called('hi')
          u = 12
        RUBY
      )
    )
  end

  def test_catch_parse_error
    assert_equal(
      [[nil, :parse_error, 'unexpected token $end']],
      parse_str(
        <<-RUBY
          if true then
        RUBY
      )
    )
  end

  def test_if_statement
    assert_equal(
      [[4, :if_not_boolean, 'Integer']],
      parse_str(
        <<-RUBY
          x = 2
          y = 3
          z = if x > y then 1 else 0 end
          z = if x then 1 else 0 end
        RUBY
      )
    )
  end

  def test_sum_types
    assert_equal(
      [[4, :var_type, 'x', 'String | nil', 'Float']],
      parse_str(
        <<-RUBY
          x = if rand() > 0.5 then 'hi' else nil end
          x = 'balls'
          x = nil
          x = 1.2
        RUBY
      )
    )
  end

  def test_block_return_type
    assert_equal(
      [[6, :block_arg_type, 'squared', '() > Integer', '() > Float'],
       [7, :fn_arg_type, '*', 'Integer', 'Float']],
      parse_str(
        <<-RUBY
          def squared
            yield * yield
          end

          a = squared { 2 }
          b = squared { 2.0 }
          a = a * 3.0
        RUBY
      )
    )
  end

  def test_block_arg_num
    assert_equal(
      [[9, :block_arg_num, 'transform', 1, 2]],
      parse_str(
        <<-RUBY
          def squared
            yield * yield
          end
          def transform(x)
            yield x
          end
          c = transform(2) { |x| squared { x } }
          c = c * 3
          d = transform(2) { |x,y| x }
        RUBY
      )
    )
  end

  def test_block_scope
    assert_equal(
      [[9, :var_type, 'q', 'String', 'Float'],
       [16, :fn_unknown, 'x', 'Object'],
       [16, :fn_arg_type, "puts", "String", "undefined"]],
      parse_str(
        <<-RUBY
          def noop
            yield
          end
          q = 'hi'
          z = noop {
            x = 10
            noop {
              y = 20
              q = 1.2
              noop {
                x * y
              }
            }
          }
          puts z.to_s
          puts x.to_s
        RUBY
      )
    )
  end
end
