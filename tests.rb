#!/usr/bin/env ruby
require 'test/unit'
require './context'

def node_to_line_nums(errors)
  errors.map { |es| [[es[0]&.loc&.line], es[1..-1]].flatten }
end

def parse_str(str)
  node_to_line_nums(Context.new.check(nil, str))
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
    # eat stderr, since the ruby parser is noisy when it gets syntax errors
    e = $stderr
    $stderr = StringIO.new
    assert_equal(
      [[nil, :parse_error, 'unexpected token $end']],
      parse_str(
        <<-RUBY
          if true then
        RUBY
      )
    )
    # restore stderr
    $stderr = e
  end

  def test_if_statement
    assert_equal(
      [[4, :expected_boolean, 'Integer']],
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
      [[4, :var_type, 'x', 'Nil | String', 'Float']],
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
      [[6, :fn_return_type, 'squared', 'Integer', 'Float'],
       [6, :block_arg_type, 'squared', '() > Integer', '() > Float'],
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
      [[10, :var_type, 'q', 'String', 'Float'],
       [17, :fn_unknown, 'x', 'Object'],
       [17, :fn_arg_type, "puts", "String", "undefined"]],
      parse_str(
        <<-RUBY
          #: fn(&() -> Integer) -> Integer
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

  def test_infer_empty_method_type
    assert_equal(
      [[4, :var_type, 'x', 'Nil', 'Integer']],
      parse_str(
        <<-RUBY
          def doNothing
          end
          x = doNothing
          x = 2
        RUBY
      )
    )
  end

  def test_class_ivars_scope
    assert_equal(
      [[13, :var_type, '@x', 'String', 'Integer'],
       [2, :ivar_unknown, '@x'],
       [18, :ivar_assign_outside_constructor, '@y']],
      parse_str(
        <<-RUBY
          def hello
            @x
            nil
          end

          def inblock
            yield
          end

          class A
            def initialize
              @x = 'world'
              @x = 2
              hello
            end

            def poop
              @y = 123
              @x = 'sd'
              inblock {
                @x
              }
            end
          end

          a = A.new
          a.poop
        RUBY
      )
    )
  end

  def test_template_methods
    ctx = Context.new
    # define a: fn<T>(T,T) -> T, and fn<T,U>(T,U,T,U,T) -> U
    _t = TemplateType.new
    _u = TemplateType.new
    ctx.object.define(Rfunc.new('fun1', _t, [_t, _t]))
    ctx.object.define(Rfunc.new('fun2', _u, [_t, _u, _t, _u, _t]))
    # define a fn<U>(T, &block(T) > U) -> U
    ctx.object.define(
      Rfunc.new('fun3', _u, [_t], block_sig: FnSig.new(_u, [_t]))
    )
    # define a fn<U>(T, &block(T) > Integer) -> U
    ctx.object.define(
      Rfunc.new('fun4', _u, [_t], block_sig: FnSig.new(ctx.object.lookup('Integer')[0], [_t]))
    )
    # define fn<T>(T) -> Self
    ctx.object.define(Rfunc.new('fun5', ctx.rself, [_t]))
  
    assert_equal(
      [[1, :fn_arg_type, 'fun1', 'Integer,Integer', 'Integer,String'],
       [3, :var_type, 'b', 'Float', 'Integer'],
       [4, :fn_arg_type, 'fun2', 'Integer,String,Integer,String,Integer', 'Integer,String,Float,Symbol,Integer'],
       [6, :var_type, 'd', 'Integer', 'Nil'],
       [8, :var_type, 'e', 'Float', 'Integer'],
       [9, :fn_unknown, 'whaa', 'String'],
       [10, :block_arg_num, 'fun3', 1, 0],
       [11, :block_arg_type, 'fun4', '(String) > Integer', '(String) > Float']],
      node_to_line_nums(ctx.check(nil,
        <<-RUBY
          a = fun1(1, 'hi')
          b = fun1(3.4, 4.4)
          b = 2
          c = fun2(1, 'x', 3.4, :hi, 2)
          d = fun2(false, 2, true, 3, false)
          d = nil
          e = fun3(1) { |x| x.to_f }
          e = 2
          f = fun3('yes') { |x| x.whaa }
          g = fun3('yes') { || nil }
          h = fun4('hi') { |x| 4.5  }
          i = 123
          i = i.fun5('unused')  # generically returns 'Self' type
        RUBY
      )
    ))
  end

  def test_self_template_type
    ctx = Context.new
    _t = TemplateType.new
    # define fn<T>(T) -> Self
    ctx.object.define(Rfunc.new('fun1', ctx.rself, [_t]))
    # define fn<T>(T, &block(Self) > Self) -> Self
    ctx.object.define(
      Rfunc.new('fun2', ctx.rself, [_t],
                block_sig: FnSig.new(ctx.rself, [ctx.rself]))
    )
  
    assert_equal(
      [[4, :var_type, 'a', 'Integer', 'String'],
       [6, :block_arg_type, 'fun2', '(Integer) > Integer', '(Integer) > Nil']],
      node_to_line_nums(ctx.check(nil,
        <<-RUBY
          a = 123
          a = a.fun1('unused')
          a = 345.fun1(4.5)
          a = 'hi'.fun1('unused')
          a = a.fun2(nil) { |x| x }
          a = a.fun2(nil) { |x| nil }
        RUBY
      ))
    )
  end

  def test_generic_type_1_arg
    assert_equal(
      [[4, :fn_arg_type, '[]=', 'Integer,Integer', 'Integer,String'],
       [7, :fn_arg_type, 'push', 'Integer', 'Nil'],
       [8, :var_type, 'a', 'Array<Integer>', 'Array<generic>'],
       [10, :fn_arg_type, 'include?', 'Integer', 'Float'],
       [12, :var_type, 'a', 'Array<Integer>', 'Array<Float>'],
       [15, :fn_arg_type, 'push', 'String', 'Integer'],
       [16, :var_type, 'c', 'Array<Float>', 'Array<String>']],
      parse_str(
        <<-RUBY
          a = Array.new
          a.push(2)
          a[0] = 3
          a[0] = 'hi'  # fails
          b = a.push(3)
          a = b
          b.push(nil)  # fails
          a = Array.new  # fails
          a.include?(3)
          a.include?(4.5)  # fails
          c = a.map { |i| i.to_f }
          a = c  # fails
          d = Array.new
          d.push('oi')
          d.push(2)  # fails
          c = d  #fails
        RUBY
      )
    )
  end

  def test_generic_late_specialization
    assert_equal(
      [[6, :var_type, 'a', 'Array<Array<Array<generic>>>', 'Array<Array<generic>>'],
       [8, :var_type, 'a', 'Array<Array<Array<Integer>>>', 'Array<Array<Integer>>']],
      parse_str(
        <<-RUBY
          a = Array.new
          b = Array.new
          c = Array.new
          a.push(b)
          b.push(c)
          a = a[0]  # fail
          a[0][0].push(1)
          a = a[0]  # fail
        RUBY
      )
    )
  end

  def test_generic_non_id
    assert_equal(
      [[4, :fn_arg_type, '==', 'Array<generic>', 'Array<generic>'],
       [7, :fn_arg_type, '==', 'Array<generic>', 'Array<Integer>']],
      parse_str(
        <<-RUBY
          a = Array.new
          b = Array.new
          a == a
          a == b  # fail
          
          b.push(1)
          a == b  # fail
          
          a.push(1)
          a == b
          a == a
        RUBY
      )
    )
  end

  def test_array_literal
    assert_equal(
      [[4, :array_mixed_types],
       [5, :fn_arg_type, '==', 'Array<generic>', 'Array<String>']],
      parse_str(
        <<-RUBY
          a = []
          b = [1,2,3]
          c = ['hello', 'dude']
          d = ['bad', 2]  # fail
          a == c  # fail
          a.push('hi')
          a == c
        RUBY
      )
    )
  end

  def test_no_block_given
    assert_equal(
      [[6, :no_block_given],
       [8, :block_arg_num, 'new', 2, 1],
       [9, :no_block_given]],
      parse_str(
        <<-RUBY
          class A
            def initialize(x, y)
              @a = yield(x, y)
            end
          end
          a = A.new(1,2)  # fail
          c = A.new(1,2) {|x, y| x + y}
          d = A.new(1,2) {|x| x}  # fail
          e = A.new(1,2)  # fail
        RUBY
      )
    )
  end

  def test_super_type_check
    assert_equal(
      [[21, :no_block_given],
       [24, :no_block_given],
       [17, :fn_arg_num, 'new', 2, 0]],
      parse_str(
        <<-RUBY
          class A
            def initialize(x, y)
              @sum = x + y
              yield(x,y)
            end
            def sum; @sum end
          end

          class B < A
            def initialize(x, y)
              super(x, y)
            end
          end

          class C < B
            def initialize()
              super  # fail
            end
          end

          a = A.new(1,2)  # fail
          a = A.new(1,2) {|a,b| p [a,b]}
          p a.sum
          b = B.new(2,3)  # fail
          p b.sum
          c = C.new
        RUBY
      )
    )
  end

  def test_logic_op
    assert_equal(
      [[2, :expected_boolean, 'Integer'],
       [3, :expected_boolean, 'Integer']],
      parse_str(
        <<-RUBY
          a = true && true || false
          a = true || 1
          a = 1 || !!1
        RUBY
      )
    )
  end

  def test_dict
    assert_equal(
      [[2, :var_type, 'a', 'Hash<generic,generic>', 'Integer'],
       [4, :fn_arg_type, '[]=', 'Symbol,Integer', 'String,Boolean'],
       [6, :var_type, 'b', 'Hash<generic,generic>', 'Boolean'],
       [8, :fn_arg_type, '[]=', 'Symbol,Integer', 'String,Float'],
       [9, :hash_mixed_types],
      ],
      parse_str(
        <<-RUBY
          a = Hash.new
          a = 1
          a[:hi] = 2
          a['hi'] = true
          b = {}
          b = false
          c = {:a => 1, b: 2}
          c['c'] = 3.0
          d = {:a => 1, 'b' => 2}
        RUBY
      )
    )
  end

  def test_annotation_tokenizer
    assert_equal(
      ["fn","<","T",",","U",">","(","Integer",",","T",")",
       "->","Array","<","U",">"
      ],
      AnnotationParser.tokenize("fn<T,U>(Integer,T) -> Array<U>")
    )
  end

  def test_recursion
    assert_equal(
      [[7, :fn_arg_type, '*', 'Integer', 'unannotated_recursive_function'],
       [11, :fn_return_type, 'factorial_bad', :unannotated_recursive_function, 'Integer']],
      parse_str(
        <<-RUBY
          #: fn(Integer) -> Integer
          def factorial_good(n)
            if n <= 1; 1 else n * factorial_good(n-1) end
          end
          # no annotation. can't figure out type in recursive case
          def factorial_bad(n)
            if n <= 1; 1 else n * factorial_bad(n-1) end
          end

          factorial_good(2)
          factorial_bad(2)
        RUBY
      )
    )

    assert_equal(
      [],
      parse_str(
        <<-RUBY
          #: fn(Integer) -> Integer
          def fac(n)
            if n == 1
              1
            else
              n * doo { fac(n-1) }
            end
          end

          def doo
            yield
          end

          p fac(6)
        RUBY
      )
    )
  end

  def test_function_annotations
    assert_equal(
      [[13, :fn_return_type, 'b', 'Float', 'Integer'],
       [15, :fn_return_type, 'd', 'Nil', 'Integer'],
       [22, :fn_return_type, 'a', 'Integer', 'Float'],
       [30, :fn_return_type, "do_thing", "Integer", "Float"],
       [30, :block_arg_type, "do_thing", "(Integer) > Integer", "(Integer) > Float"]],
      parse_str(
        <<-RUBY
          #: fn(Integer)
          def a(x); nil end
          #: fn(Integer) -> Float
          def b(x); x end
          #: fn(Integer) -> Float
          def c(x); x.to_f end
          #: fn(Integer)
          def d(x); x end
          #: fn()
          def e(); end

          a(2)
          b(2)  # fail
          c(2)
          d(2)  # fail
          e

          class A
            #: fn(Float) -> Integer
            def self.a(x); x end
          end
          A.a(1.0)

          #: fn(Integer, &(Integer) -> Integer) -> Integer
          def do_thing(x)
            yield x
          end

          do_thing(2) { |a| a * 2 }
          do_thing(2) { |a| a.to_f }
        RUBY
      )
    )
  end

  def test_rescue
    assert_equal(
      [[13, :var_type, 'a', 'Float | Integer', 'String']],
      parse_str(
        <<-RUBY
          def func1
            begin
              3
            rescue RuntimeError, StandardError => e
              4
            else
              5.0
            ensure
              'hi'
            end
          end
          a = func1
          a = 'hi'  # fail
        RUBY
      )
    )
    assert_equal(
      [[9, :var_type, 'b', 'Integer', 'String']],
      parse_str(
        <<-RUBY
          def func2
            begin
              3
            rescue RuntimeError, StandardError => e
              4
            end
          end
          b = func2
          b = 'oi'
        RUBY
      )
    )
    assert_equal(
      [[7, :var_type, 'c', 'Integer', 'Float']],
      parse_str(
        <<-RUBY
          def func3
            begin
              3
            end
          end
          c = func3
          c = 4.0
        RUBY
      )
    )
    assert_equal(
      [[9, :var_type, 'd', 'Integer', 'Nil']],
      parse_str(
        <<-RUBY
          def func4
            begin
              3
            rescue => e
              4
            end
          end
          d = func4
          d = nil
        RUBY
      )
    )
    assert_equal(
      [[5, :fn_unknown, 'hi', 'StandardError'],
       [10, :var_type, 'e', 'Integer', 'Nil']],
      parse_str(
        <<-RUBY
          def func5
            begin
              3
            rescue => e
              e.hi
              4
            end
          end
          e = func5
          e = nil
        RUBY
      )
    )
    assert_equal(
      [[5, :fn_unknown, 'poo', 'RuntimeError'],
       [10, :var_type, 'f', 'Integer', 'Nil']],
      parse_str(
        <<-RUBY
          def func6
            begin
              3
            rescue RuntimeError => e
              e.poo
              4
            end
          end
          f = func6
          f = nil
        RUBY
      )
    )
    assert_equal(
      [[3, :rescue_exception_type, 'String']],
      parse_str(
        <<-RUBY
          def func6
            begin
            rescue 'hello'
            end
          end
          func6
        RUBY
      )
    )
  end

  def test_case_match
    assert_equal(
      [[10, :var_type, 'a', 'Nil | String', 'Symbol']],
      parse_str(
        <<-RUBY
          def f(x)
            case x
            when 0
              'hi'
            when 1
              'oi'
            end
          end
          a = f(1)
          a = :hi
        RUBY
      )
    )
    assert_equal(
      [[12, :var_type, 'a', 'Integer | String', 'Symbol']],
      parse_str(
        <<-RUBY
          def f(x)
            case x
            when 0
              'hi'
            when 1
              'oi'
            else
              123
            end
          end
          a = f(1)
          a = :hi
        RUBY
      )
    )
    assert_equal(
      [[5, :match_type, 'Integer', 'String']],
      parse_str(
        <<-RUBY
          def f(x)
            case x
            when 0
              'hi'
            when 'foo'  # fail
              'oi'
            end
          end
          f(1)
        RUBY
      )
    )
  end

  def test_weak_scopes
    assert_equal(
      [[4, :var_type, 'x', 'Integer', 'String'],
       [8, :lvar_unknown, 'y'],
       [11, :lvar_unknown, 'a'],
       [12, :lvar_unknown, 'y']],
      parse_str(
        <<-RUBY
          x = 2
          if (a = rand() > 0.5)
            puts a.to_s
            x = 'hi'
            y = x
            puts y.to_s
          else
            y  # fails
          end
          x
          a  # fails
          y  # fails
        RUBY
      )
    )
  end

  def test_csend
    assert_equal(
      [[6, :var_type, 'x', 'Integer | Nil | String', 'Float'],
       [9, :var_type, 'a', 'Nil | String', 'Integer'],
       [10, :fn_unknown, 'whaa', 'Integer | String'],
       [11, :invalid_safe_send, 'Integer']],
      parse_str(
        <<-RUBY
          w = if true then 'a' else nil end
          x = if true then 'a' elsif false then 1 else nil end
          x = w
          y = if true then 1 else nil end
          z = 1
          x = 2.0
          x&.to_s
          a = y&.to_s
          a = 1
          x&.whaa
          z&.to_s
        RUBY
      )
    )
  end

  def test_dstr
    assert_equal(
      [[4, :fn_unknown, 'whatever', 'Array<Integer>'],
       [4, :fn_arg_type, 'puts', 'String', 'undefined']],
      parse_str(
         'a = "hi"
          b = [1,2,3]
          puts "#{a} #{b.join(\',\')}"
          puts "#{a} #{b.whatever}"
          '
      )
    )
  end
end
