$for(entries)$
**$entries.what$**$if(entries.with)$ --- $entries.with$$endif$ *$entries.when$*$if(entries.where)$, $entries.where$$endif$
$if(entries.why)$
$for(entries.why)$- $entries.why$
$endfor$$endif$
$endfor$
