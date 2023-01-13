; inherits: c
[
 (declaration)
 (conditional_expression)
 (do_statement)
 (return_statement)
] @indent

((if_statement consequence: (_)) @indent)

"else" @dedent

((parenthesized_expression) @aligned_indent
 (#set! "delimiter" "()"))
((for_statement) @aligned_indent
 (#set! "delimiter" "()"))
