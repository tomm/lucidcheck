#!/usr/bin/env ruby
require 'parser/current'
require 'pry'
require 'set'

class Rscopebinding
  attr_accessor :name, :type
  def initialize(name, type)
    @name = name
    @type = type
    if type && !type.kind_of?(Rscopebinding)
      raise "Weird type passed to Rscopebinding.initialize: #{type} (#{type.class})"
    end
  end

  def to_s
    @name
  end
end

class Rlvar < Rscopebinding
end

class Rconst < Rscopebinding
end

class Rfunc < Rscopebinding
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
      return [@type, [[node, :fn_arg_num, @name, @arg_types.length-1, args.length-1]]]
    end

    # collect arg types if we know none
    if @arg_types == [nil]*@arg_types.length
      @arg_types = args
    end

    # check arg types. ignore first argument, since we have already resolved class lookup
    if @arg_types.drop(1) != args.drop(1)
      return [@type, [type_error(node, args)]]
    end

    [@type, []]
  end

  private

  def type_error(node, args)
    [node, :fn_arg_type, @name, @arg_types.drop(1).join(','), args.drop(1).map(&:name).join(',')]
  end
end

class Rmetaclass < Rscopebinding
  def initialize
    super('Class', nil)
  end
end

class Rclass < Rscopebinding
  def initialize(name, parent_class)
    @metaclass = Rmetaclass.new
    super(name, @metaclass)
    @parent = parent_class
    @rmethods = {}
  end

  def lookup(method_name)
    m = @rmethods[method_name]
    if m
      m
    elsif @parent
      @parent.lookup(method_name)
    else
      nil
    end
  end

  def define(rscopebinding)
    @rmethods[rscopebinding.name] = rscopebinding
  end
end

def make_root
  robject = Rclass.new('Object', nil)
  # denny is right
  rstring  = robject.define(Rclass.new('String', robject))
  rvoid    = robject.define(Rclass.new(:void, robject))
  rinteger = robject.define(Rclass.new('Integer', robject))
  rboolean = robject.define(Rclass.new('Boolean', robject))
  
  robject.define(Rfunc.new('require', rvoid, [rvoid, rstring]))
  robject.define(Rfunc.new('puts', rvoid, [rvoid, rstring]))
  robject.define(Rfunc.new('exit', rvoid, [rvoid, rinteger]))

  rstring.define(Rfunc.new('upcase', rstring, [rstring]))

  robject
end

class Context
  def self.error_msg(filename, e)
    "Error in #{filename} line #{e[0].loc.line}: " +
      case e[1]
      when :type_unknown
        "Type '#{e[2]}' not found in this scope"
      when :fn_unknown
        "Type '#{e[3]}' has no method named '#{e[2]}'"
      when :const_unknown
        "Constant '#{e[2]}' not found in this scope"
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
    @robject = make_root()
    @rvoid = @robject.lookup(:void)
    @scope = [@robject]
    @errors = []
    @ast = Parser::CurrentRuby.parse(source)
  end

  def push_scope(scope)
    @scope.push(scope)
  end

  def pop_scope
    @scope.pop
  end

  def scope_top
    @scope.last
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
      scope_top.lookup(node.children[0].to_s).type
    when :send
      n_send(node)
    when :lvasgn
      n_lvasgn(node)
    when :casgn
      n_casgn(node)
    when :class
      n_class(node)
    when :module
      # ignore for now :)
    when :if
      type1 = n_expr(node.children[1])
      type2 = n_expr(node.children[2])
      if type1 == type2
        type1
      else
        raise "Sum types not yet supported"
      end
    when :float
      type_lookup!(node, @robject, 'Float')
    when :int
      type_lookup!(node, @robject, 'Integer')
    when :str
      type_lookup!(node, @robject, 'String')
    when :dstr # XXX could check dstr
      type_lookup!(node, @robject, 'String')
    when :true
      type_lookup!(node, @robject, 'Boolean')
    when :false
      type_lookup!(node, @robject, 'Boolean')
    when :const
      c = scope_top.lookup(node.children[1].to_s)
      if c
        c.type
      else
        @errors << [node, :const_unknown, node.children[1].to_s]
      end
    else
      @errors << [node, :unexpected]
      nil
    end
  end

  def n_class(node)
    class_name = node.children[0].children[1].to_s
    parent_class_name = node.children[1]&.children&.last&.to_s
    parent_class = parent_class_name == nil ? @robject : scope_top.lookup(parent_class_name)

    new_class = Rclass.new(
      class_name,
      parent_class
    )
    scope_top.define(new_class)

    push_scope(new_class)
    r = n_expr(node.children[2])
    pop_scope()

    r
  end

  def type_lookup!(node, scope, type_identifier)
    if type_identifier == nil
      @errors << [node, :inference_failed]
      return nil
    elsif type_identifier == :error
      # error happened in resolving type. don't report another error
      return nil
    end

    type = scope.lookup(type_identifier)

    if type == nil then
      # type not found
      @errors << [node, :type_unknown, type_identifier]
      return nil
    else
      return type
    end
  end

  def n_lvasgn(node)
    name = node.children[0].to_s
    type = n_expr(node.children[1])

    if type == nil
      # error already reported. do nothing
    elsif scope_top.lookup(name) == nil
      scope_top.define(Rlvar.new(name, type))
    elsif scope_top.lookup(name).type != type
      @errors << [node, :var_type, name, scope_top.lookup(name).type.name, type.name]
    end
  end

  def n_casgn(node)
    name = node.children[1].to_s
    type = n_expr(node.children[2])

    if type == nil
      # error already reported. do nothing
    elsif scope_top.lookup(name) == nil
      scope_top.define(Rconst.new(name, type))
    else
      @errors << [node, :const_redef, name]
    end
  end

  # returns return type of method/function (or nil if not determined)
  def n_send(node)
    self_type = node.children[0] ? n_expr(node.children[0]) : @rvoid
    if self_type != @rvoid
      scope = self_type
      raise "Checker bug: Type unknown: #{self_type}" if scope == nil
    else
      scope = scope_top
    end
    name = node.children[1].to_s
    # consider 'self' to be a normal param
    arg_types = [self_type] + node.children[2..-1].map {|n| n_expr(n) }
    num_args = arg_types.length

    if scope.lookup(name) == nil
      @errors << [node, :fn_unknown, name, scope.name]
      return
    elsif scope.lookup(name).kind_of?(Rfunc)
      return_type, errors = scope.lookup(name).called_by!(node, arg_types)
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
    name = node.children[0].to_s
    num_args = node.children[1].children.length
    if node.children[2] == nil
      return_type = @rvoid
    else
      return_type = n_expr(node.children[2])
    end
    # define function with no known argument types (so far)
    scope_top.define(Rfunc.new(name, return_type, [nil]*(num_args+1)))
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
