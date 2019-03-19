def hi(name)
  puts "num #{name}"
end

hello(123) # fails
hi('tom', 'thing') # fails
hi('joe')
hi(123) # fails
y = 'blob'
x = 'oioi'
x = 'yes'
x = 123 # fails
x = y
hi(x)

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
