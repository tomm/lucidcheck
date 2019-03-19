#!/usr/bin/env ruby
require './lucidcheck'
require 'test/unit'

def node_to_line_nums(errors)
  errors.map { |es| [[es[0].loc.line], es[1..-1]].flatten }
end

def parse(filename)
  node_to_line_nums(
    Context.new(
      File.open(filename).read
    ).check
  )
end

class TestLudidCheck < Test::Unit::TestCase
  def test_example1
    es = parse('tests/test1.rb')
    assert_equal([5, :fn_unknown, :hello], es[0])
    assert_equal([6, :fn_arg_num, :hi, 1, 2], es[1])
    assert_equal([8, :fn_arg_type, :hi, 'str', 'int'], es[2])
    assert_equal([12, :var_type, :x, 'str', 'int'], es[3])
    assert_equal([19, :fn_arg_num, :returns_int, 0, 1], es[4])
    assert_equal([21, :var_type, :z, 'int', 'true'], es[5])
    assert_equal(nil, es[6])
  end
end
