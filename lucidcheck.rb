#!/usr/bin/env ruby
require 'parser/current'
require 'pry'
require 'set'

# Sum type. ie Set[:str, nil] = String | nil
S = Set

class RScopeBinding
  attr_accessor :name, :type
  def initialize(name, type)
    @name = name
    @type = type
  end
end

class Rlvar < RScopeBinding
end

class Rconst < RScopeBinding
end

class Rfunc < RScopeBinding
  def initialize(name, return_type, arg_types)
    super(name, return_type)
    @arg_types = arg_types
  end

  # @returns [return_type, errors]
  # updates @arg_types with param types if nil
  def called_by!(node, args)
    args.each_with_index {|a,i|
      if a == nil
        return [@type, [type_error(node, args)]]
      end
    }
    if args.length != @arg_types.length
      return [@type, [[node, :fn_arg_num, @name, @arg_types.length, args.length]]]
    end

    # collect arg types if we know none
    if @arg_types == [nil]*@arg_types.length
      @arg_types = args
    end

    if @arg_types != args
      return [@type, [type_error(node, args)]]
    end

    [@type, []]
  end

  private

  def type_error(node, args)
    [node, :fn_arg_type, @name, @arg_types.map(&:to_s).join(','), args.map(&:to_s).join(',')]
  end
end

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
      when :inference_failed
        "Cannot infer type. Annotation needed."
      when :const_redef
        "Cannot redefine constant '#{e[2]}'"
      when :unexpected
        "LucidCheck bug! No parse: token #{e[0].type}"
      else
        e.to_s
      end
  end

  def initialize(source)
    @scope = {
      require: Rfunc.new('require', :void, ['str']),
      puts: Rfunc.new('puts', :void, ['str']),
      exit: Rfunc.new('exit', :void, ['int']),
    }
    @errors = []
    @ast = Parser::CurrentRuby.parse(source)
  end

  def check
    n_expr(@ast)
    @errors
  end

  private

  #: returns type
  def n_expr(node)
    if node == nil
      return
    end
    case node.type
    when :begin
      node.children.map { |child| n_expr(child) }.last
    when :def
      n_def(node)
    when :lvar
      @scope[node.children[0]].type
    when :send
      n_send(node)
    when :lvasgn
      n_lvasgn(node)
    when :casgn
      n_casgn(node)
    when :class
      # ignore for now :)
    when :module
      # ignore for now :)
    when :if
      type1 = n_expr(node.children[1])
      type2 = n_expr(node.children[2])
      if type1 == type2
        type1
      else
        "#{type1}|#{type2}"
      end
    when :int
      'int'
    when :str
      'str'
    when :dstr # XXX could check dstr
      'str'
    when :true
      'boolean'
    when :false
      'boolean'
    when :const
      node.children[1].to_s
    else
      @errors << [node, :unexpected]
      nil
    end
  end

  def n_lvasgn(node)
    name = node.children[0]
    type = n_expr(node.children[1])

    if type == nil
      @errors << [node, :inference_failed]
    elsif type == :error
      # error happened in resolving type. don't report another error
    elsif @scope[name] == nil
      @scope[name] = Rlvar.new(name, type)
    elsif @scope[name].type != type
      @errors << [node, :var_type, name, @scope[name].type, type]
    end
  end

  def n_casgn(node)
    name = node.children[1]
    type = n_expr(node.children[2])

    if type == nil
      @errors << [node, :inference_failed]
    elsif type == :error
      # error happened in resolving type. don't report another error
    elsif @scope[name] == nil
      @scope[name] = Rconst.new(name, type)
    else
      @errors << [node, :const_redef, name]
    end
  end

  # returns return type of method/function (or nil if not determined)
  def n_send(node)
    _self = node.children[0]
    unexpected!("call with self?? value", node) if _self != nil

    name = node.children[1]
    arg_types = node.children[2..-1].map {|n| n_expr(n) }
    num_args = arg_types.length

    if @scope[name] == nil
      @errors << [node, :fn_unknown, name]
      return
    elsif @scope[name].instance_of?(Rfunc)
      return_type, errors = @scope[name].called_by!(node, arg_types)
      @errors = @errors + errors
      if return_type == nil and !errors.empty?
        return :error
      else
        return return_type
      end
    else
      @errors << [node, :not_a_function, name]
      return
    end
  end

  def n_def(node)
    name = node.children[0]
    num_args = node.children[1].children.length
    if node.children[2] == nil
      return_type = :void
    else
      return_type = n_expr(node.children[2])
    end
    # define function with no known argument types (so far)
    @scope[name] = Rfunc.new(name, return_type, [nil]*num_args)
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
