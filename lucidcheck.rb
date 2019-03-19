#!/usr/bin/env ruby
require 'parser/current'
require 'pry'
require 'set'

# Sum type. ie Set[:str, nil] = String | nil
S = Set

class Context
  def self.error_msg(filename, e)
    "Error in #{filename} line #{e[0].loc.line}: " +
      case e[1]
      when :fn_unknown
        "Unknown function '#{e[2]}'"
      when :fn_arg_num
        "Function '#{e[2]}' expected #{e[3]} arguments but found #{e[4]}"
      when :fn_arg_type
        "Function '#{e[2]}' arguments have inferred type (#{e[3]}) but was passed (#{e[4]})"
      when :var_type
        "Cannot reassign variable '#{e[2]}' of type #{e[3]} with value of type #{e[4]}"
      when :unexpected
        "No parse! (token #{e[0].type})"
      else
        e.to_s
      end
  end

  def initialize(source)
    @scope = {
      require: [:fn, 1, ['str'], nil],
      puts: [:fn, 1, ['str'], :nil]
    }
    @errors = []
    @ast = Parser::CurrentRuby.parse(source)
  end

  def check
    n_root(@ast)
    @errors
  end

  private

  def n_root(node)
    if node == nil
      return
    end
    case node.type
    when :begin
      node.children.map { |child| n_root(child) }.flatten
    when :def
      n_def(node)
    when :send
      n_send(node)
    when :lvasgn
      n_lvasgn(node)
    when :class
      # ignore for now :)
    when :module
      # ignore for now :)
    else
      unexpected!("root node", node)
    end
  end

  def n_typeof_rval(node)
    case node.type
    when :lvar
      @scope[node.children[0]]&.[](3)
    when :send
      n_send(node)
    when :dstr # XXX could check dstr
      'str'
    else
      node.type.to_s
    end
  end

  def n_lvasgn(node)
    name = node.children[0]
    type = n_typeof_rval(node.children[1])

    if type == nil
      # can't type check. bail
      puts "warning -- skipping type check in lvasgn, line #{node.loc.line}"
      return
    end

    _def = [:lvar, 0, [], type]

    if type == :send
      @errors << [node, :unexpected]
    elsif @scope[name] != nil && @scope[name] != _def
      @errors << [node, :var_type, name, @scope[name][3], type]
    else
      @scope[name] = [:lvar, 0, [], type]
    end
  end

  # returns return type of method/function (or nil if not determined)
  def n_send(node)
    _self = node.children[0]
    unexpected!("call with self?? value", node) if _self != nil

    name = node.children[1]
    arg_types = node.children[2..-1].map {|n| n_typeof_rval(n) }
    num_args = arg_types.length

    if @scope[name] == nil
      @errors << [node, :fn_unknown, name]
      return
    elsif @scope[name][1] != num_args
      @errors << [node, :fn_arg_num, name, @scope[name][1], num_args]
      return
    end

    if @scope[name][2] == [nil]*@scope[name][1]
      # argument types not known yet. can set from this first call
      @scope[name][2] = arg_types
    elsif @scope[name][2] != arg_types
      @errors << [node, :fn_arg_type, name,
                  @scope[name][2].map(&:to_s).join(','),
                  arg_types.map(&:to_s).join(',')]
      return
    end
    # well-typed call
    @scope[name][3]
  end

  def n_def(node)
    name = node.children[0]
    num_args = node.children[1].children.length
    return_type = n_typeof_rval(node.children[2])
    @scope[name] = [:fn, num_args, [nil]*num_args, return_type]
  end

  def unexpected!(position, node)
    @errors << [node, :unexpected]
  end
end

if __FILE__ == $0
  if ARGV.length < 1 then
    puts "Usage: ./turbocop.rb file1.rb file2.rb etc..."
  end

  got_errors = false
  ARGV.each do |filename|
    source = File.open(filename).read

    errors = Context.new(source).check
    if !errors.empty?
      got_errors = true
      puts errors.map{|e| Context.error_msg(filename, e)}.join("\n")
      puts "FAIL! #{filename}: #{errors.length} issues found."
    else
      puts "Pass! #{filename}"
    end
  end
  if got_errors then
    exit 1
  else
    exit 0
  end
end
