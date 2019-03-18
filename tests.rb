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

class TestTurbocop < Test::Unit::TestCase
  def test_example1
    assert_equal(
      [
        [5, :fn_unknown, :hello],
        [6, :fn_arg_num, :hi, 1, 2],
        [8, :fn_arg_type, :hi, 'str', 'int']
      ],
      parse('example1.rb')
    )
  end
end
