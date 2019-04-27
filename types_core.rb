def make_robject
  robject = Rclass.new('Object', nil)

  _K = TemplateType.new
  _V = TemplateType.new
  _T = TemplateType.new
  _U = TemplateType.new
  rself = SelfType.new
  robject.define(rself)
  # denny is right
  rstring  = robject.classdef('String', robject)
  #rsymbol  = robject.classdef('Symbol', robject)
  rnil     = robject.classdef('Nil', robject)
  rinteger = robject.classdef('Integer', robject)
  rfloat   = robject.classdef('Float', robject)
  rboolean = robject.classdef('Boolean', robject)
  rarray   = robject.classdef('Array', robject, [_T])
  rtuple   = robject.classdef('Tuple', robject, ([TemplateType]*16).map(&:new), can_underspecialize: true)
  rhash    = robject.classdef('Hash', robject, [_K, _V])
  rrange   = robject.classdef('Range', robject, [_T])
  rfile    = robject.classdef('File', robject)
  # or is he? :-/
  rexception = robject.classdef('Exception', robject)
  rstandarderror = robject.classdef('StandardError', rexception)
  rruntimeerror = robject.classdef('RuntimeError', rstandarderror)

  robject.define(rarray[[rstring]], bind_to: 'ARGV')
  robject.define(rstring, bind_to: '$0')
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

  # XXX incomplete
  rfile.metaclass.define(Rfunc.new('open', rfile, [rstring]))
  rfile.define(Rfunc.new('read', rstring, []))

  rrange.define(Rfunc.new("to_a", rarray[[_T]], []))

  rhash.metaclass.define(Rfunc.new('new', rhash[[_K, _V]], []))
  rhash.define(Rfunc.new('[]=', _V, [_K, _V]))
  rhash.define(Rfunc.new('[]', _V, [_K]))
  rhash.define(Rfunc.new('keys', rarray[[_K]], []))

  rarray.metaclass.define(Rfunc.new('new', rarray[[_T]], []))
  rarray.define(Rfunc.new('length', rinteger, []))
  rarray.define(Rfunc.new('clear', rself, []))
  rarray.define(Rfunc.new('push', rself, [_T]))
  rarray.define(Rfunc.new('<<', rself, [_T]))
  rarray.define(Rfunc.new('*', rself, [rinteger]))
  rarray.define(Rfunc.new('[]', _T, [rinteger]))
  rarray.define(Rfunc.new('[]=', _T, [rinteger, _T]))
  rarray.define(Rfunc.new('include?', rboolean, [_T]))
  # XXX incomplete
  rarray.define(Rfunc.new('join', rstring, [rstring]))
  rarray.define(Rfunc.new('empty?', rboolean, []))
  rarray.define(Rfunc.new('map', rarray[[_U]], [], block_sig: FnSig.new(_U, [_T])))
  rarray.define(Rfunc.new('select', rself, [], block_sig: FnSig.new(rboolean, [_T])))
  rarray.define(Rfunc.new('each', rarray[[_T]], [], block_sig: FnSig.new(_U, [_T])))
  rarray.define(Rfunc.new('==', rboolean, [rself]))

  rstring.define(Rfunc.new('upcase', rstring, []))
  # XXX incomplete
  rstring.define(Rfunc.new('split', rarray[[rstring]], [rstring]))
  rstring.define(Rfunc.new('+', rstring, [rstring]))
  rstring.define(Rfunc.new('==', rboolean, [rstring]))

  rinteger.define(Rfunc.new('+', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('-', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('*', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('/', rinteger, [rinteger]))
  rinteger.define(Rfunc.new('>', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('>=', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('<', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('<=', rboolean, [rinteger]))
  rinteger.define(Rfunc.new('==', rboolean, [rinteger]))

  rfloat.define(Rfunc.new('+', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('-', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('*', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('/', rfloat, [rfloat]))
  rfloat.define(Rfunc.new('>', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('>=', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('<', rboolean, [rfloat]))
  rfloat.define(Rfunc.new('<=', rboolean, [rfloat]))

  rboolean.define(Rfunc.new('==', rboolean, [rboolean]))

  robject
end
