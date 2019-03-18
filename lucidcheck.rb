#!/usr/bin/env ruby
require 'parser/current'
require 'pry'

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
      when :unexpected
        "No parse! Turbocop doesn't understand this file! (token #{e[0].type})"
      else
        e.to_s
      end
  end

  def initialize(source)
    @scope = {
      require: [1, [:str], nil]
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
    elsif node.type == :begin
      node.children.map { |child| n_root(child) }.flatten
    elsif node.type == :def
      n_def(node)
    elsif node.type == :send
      n_send(node)
    elsif node.type == :class
      # ignore for now :)
    elsif node.type == :module
      # ignore for now :)
    else
      unexpected!("root node", node)
    end
  end

  def n_send(node)
    _self = node.children[0]
    unexpected!("call with self?? value", node) if _self != nil

    name = node.children[1]
    arg_types = node.children[2..-1].map(&:type)
    num_args = arg_types.length

    if @scope[name] == nil
      @errors << [node, :fn_unknown, name]
      return
    elsif @scope[name][0] != num_args
      @errors << [node, :fn_arg_num, name, @scope[name][0], num_args]
      return
    end

    if @scope[name][1] == [nil]*@scope[name][0]
      # argument types not known yet. can set from this first call
      @scope[name][1] = arg_types
    end

    if @scope[name][1] != arg_types
      @errors << [node, :fn_arg_type, name,
                  @scope[name][1].map(&:to_s).join(','),
                  arg_types.map(&:to_s).join(',')]
      return
    end
  end

  def n_def(node)
    name = node.children[0]
    num_args = node.children[1].children.length
    @scope[name] = [num_args, [nil]*num_args, nil]
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
