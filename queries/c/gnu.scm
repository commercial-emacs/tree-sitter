; inherits: c

((if_statement consequence: (_)) @indent)

"else" @dedent

[
  ")"
  "}"
  (statement_identifier)
] @branch

((parenthesized_expression) @aligned_indent
 (#set! "delimiter" "()"))
((for_statement) @aligned_indent (#set! "delimiter" "()"))
