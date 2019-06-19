def populate_robject(robject)

  _K = TemplateType.new
  _V = TemplateType.new
  _T = TemplateType.new
  _U = TemplateType.new
  rself = SelfType.new
  robject.define(rself)
  
  rstring = robject.lookup('String')[0].metaclass_for
  rinteger = robject.lookup('Integer')[0].metaclass_for
  rfloat   = robject.lookup('Float')[0].metaclass_for
  rboolean   = robject.lookup('Boolean')[0].metaclass_for
  rnil   = robject.lookup('Nil')[0].metaclass_for

  #rsymbol  = robject.classdef('Symbol', robject)
  rarray   = robject.classdef('Array', robject, [_T])
  rtuple   = robject.classdef('Tuple', robject, ([TemplateType]*16).map(&:new), can_underspecialize: true)
  rhash    = robject.classdef('Hash', robject, [_K, _V])
  rrange   = robject.classdef('Range', robject, [_T])

  robject.define(rarray[[rstring]], bind_to: 'ARGV')
  robject.define(rstring, bind_to: '$0')
  # XXX wrong. many of these are private on object. actually on Kernel
  robject.define(Rfunc.new('__dir__', rstring, []))
  robject.define(Rfunc.new('!', rboolean, []))
  robject.define(Rfunc.new('!=', rboolean, [robject]))
  robject.define(Rfunc.new('puts', rnil, [rstring]))
  robject.define(Rfunc.new('p', _T, [_T]))
  robject.define(Rfunc.new('exit', rnil, [rinteger]))
  robject.define(Rfunc.new('rand', rfloat, []))
  robject.define(Rfunc.new('to_s', rstring, []))
  robject.define(Rfunc.new('to_f', rfloat, []))
  robject.define(Rfunc.new('to_i', rinteger, []))
  robject.define(Rfunc.new('is_a?', rboolean, [robject.metaclass]))

  rrange.define(Rfunc.new("to_a", rarray[[_T]], []))

  rhash.metaclass.define(Rfunc.new('new', rhash[[_K, _V]], []))
  rhash.define(Rfunc.new('[]=', _V, [_K, _V]))
  rhash.define(Rfunc.new('[]', _V, [_K]))
  rhash.define(Rfunc.new('keys', rarray[[_K]], []))

  rarray.metaclass.define(Rfunc.new('new', rarray[[_T]], []))
  rarray.define(Rfunc.new('length', rinteger, []))
  rarray.define(Rfunc.new('clear', rself, []))
  rarray.define(Rfunc.new('push', rself, [_T]))
  # XXX doesn't work yet
  #rarray.define(Rfunc.new('zip', rarray[[rtuple[[_T, _U ]] ]], [rarray[[_U]]]))
  rarray.define(Rfunc.new('<<', rself, [_T]))
  rarray.define(Rfunc.new('*', rself, [rinteger]))
  rarray.define(Rfunc.new('uniq', rself, []))
  rarray.define(Rfunc.new('uniq!', rself, []))
  rarray.define(Rfunc.new('[]', _T, [rinteger]))
  rarray.define(Rfunc.new('first', sum_of_types([_T, rnil]), []))
  rarray.define(Rfunc.new('last', sum_of_types([_T, rnil]), []))
  rarray.define(Rfunc.new('[]=', _T, [rinteger, _T]))
  rarray.define(Rfunc.new('include?', rboolean, [_T]))
  # XXX incomplete
  rarray.define(Rfunc.new('join', rstring, [rstring]))
  rarray.define(Rfunc.new('empty?', rboolean, []))
  rarray.define(Rfunc.new('map', rarray[[_U]], [], block_sig: FnSig.new(_U, [_T])))
  rarray.define(Rfunc.new('select', rself, [], block_sig: FnSig.new(rboolean, [_T])))
  rarray.define(Rfunc.new('each', rarray[[_T]], [], block_sig: FnSig.new(_U, [_T])))
  rarray.define(Rfunc.new('==', rboolean, [rself]))

  robject
end
