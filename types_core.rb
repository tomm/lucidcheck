def make_robject
  robject = Rclass.new('Object', nil)

  _K = TemplateType.new
  _V = TemplateType.new
  _T = TemplateType.new
  _U = TemplateType.new
  # denny is right
  rstring  = robject.define(Rclass.new('String', robject))
  rsymbol  = robject.define(Rclass.new('Symbol', robject))
  rnil     = robject.define(Rclass.new('Nil', robject))
  rinteger = robject.define(Rclass.new('Integer', robject))
  rfloat   = robject.define(Rclass.new('Float', robject))
  rboolean = robject.define(Rclass.new('Boolean', robject))
  rarray   = robject.define(Rclass.new('Array', robject, template_params: [_T]))
  rtuple   = robject.define(Rclass.new('Tuple', robject, 
                                       template_params: ([TemplateType]*16).map(&:new)))
  rhash    = robject.define(Rclass.new('Hash', robject, template_params: [_K, _V]))
  rrange   = robject.define(Rclass.new('Range', robject, template_params: [_T]))
  rfile    = robject.define(Rclass.new('File', robject))
  rexception = robject.define(Rclass.new('Exception', robject))
  rstandarderror = robject.define(Rclass.new('StandardError', rexception))
  rruntimeerror = robject.define(Rclass.new('RuntimeError', rstandarderror))
  rself    = robject.define(SelfType.new)

  robject.define(Rconst.new('ARGV', rarray[[rstring]]))
  robject.define(Rlvar.new('$0', rstring))
  robject.define(Rfunc.new('!', rboolean, []))
  robject.define(Rfunc.new('puts', rnil, [rstring]))
  robject.define(Rfunc.new('p', _T, [_T]))
  robject.define(Rfunc.new('exit', rnil, [rinteger]))
  robject.define(Rfunc.new('rand', rfloat, []))
  robject.define(Rfunc.new('to_s', rstring, []))
  robject.define(Rfunc.new('to_f', rfloat, []))
  robject.define(Rfunc.new('to_i', rinteger, []))

  # XXX incomplete
  rfile.metaclass.define(Rfunc.new('open', rfile, [rstring]))
  rfile.define(Rfunc.new('read', rstring, []))

  rrange.define(Rfunc.new("to_a", rarray[[_T]], []))

  rhash.metaclass.define(Rfunc.new('new', rhash[[_K, _V]], []))
  rhash.define(Rfunc.new('[]=', _V, [_K, _V]))
  rhash.define(Rfunc.new('[]', _V, [_K]))

  rarray.metaclass.define(Rfunc.new('new', rarray[[_T]], []))
  rarray.define(Rfunc.new('length', rinteger, []))
  rarray.define(Rfunc.new('clear', rself, []))
  rarray.define(Rfunc.new('push', rself, [_T]))
  rarray.define(Rfunc.new('[]', _T, [rinteger]))
  rarray.define(Rfunc.new('[]=', _T, [rinteger, _T]))
  rarray.define(Rfunc.new('include?', rboolean, [_T]))
  # XXX incomplete
  rarray.define(Rfunc.new('join', rstring, [rstring]))
  rarray.define(Rfunc.new('empty?', rboolean, []))
  rarray.define(Rfunc.new('map', rarray[[_U]], [], block_sig: FnSig.new(_U, [_T])))
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
