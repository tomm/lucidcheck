#!/usr/bin/env ruby
require_relative 'context'

if __FILE__ == $0
  if ARGV.length < 1 then
    puts "Usage: lucidcheck file1.rb file2.rb etc..."
  end

  if ARGV == ['--version']
    puts "0.1.0"
    exit 0
  end

  got_errors = false
  ARGV.select { |a| a != '-a' }.each do |filename|
    source = File.open(filename).read

    # scoped checking is broken, so just do all
    ctx = Context.new(check_all: true)  # ARGV.include?('-a'))
    errors = ctx.check(filename, source)
    errors.uniq!
    if !errors.empty?
      got_errors = true
      puts errors.map{|e| ctx.error_msg(e)}.join("\n")
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
