$for(entries)$
#block(below: 1em)[
#strong[$entries.what$]$if(entries.with)$ --- $entries.with$$endif$$if(entries.when)$#h(1fr)$entries.when$$endif$$if(entries.where)$#linebreak()
#emph[$entries.where$]$endif$
$if(entries.why)$
$for(entries.why)$- $entries.why$
$endfor$
$endif$
]
$endfor$
