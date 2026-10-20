if exists("b:current_syntax")
  finish
endif

syntax match bruSection /^[a-zA-Z][a-zA-Z0-9:_-]*\s*{\s*$/
syntax match bruClose /^}\s*$/
syntax match bruProperty /^\s*[a-zA-Z][a-zA-Z0-9_.-]*\s*:/
syntax match bruVariable /{{[^}]*}}/
syntax match bruComment /^\s*#.*$/
syntax region bruString start=/"/ skip=/\\"/ end=/"/
syntax keyword bruBoolean true false
syntax keyword bruNull null none
syntax match bruNumber /\v<[-+]?\d+(\.\d+)?>

highlight default link bruSection Keyword
highlight default link bruClose Delimiter
highlight default link bruProperty Identifier
highlight default link bruVariable Special
highlight default link bruComment Comment
highlight default link bruString String
highlight default link bruBoolean Boolean
highlight default link bruNull Constant
highlight default link bruNumber Number

let b:current_syntax = "bruno"
