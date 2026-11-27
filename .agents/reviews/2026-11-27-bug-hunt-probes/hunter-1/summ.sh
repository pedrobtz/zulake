#!/bin/sh
# summarise REF-DIFF lines of a matrix output: one example per (first symbol, label), R errors excluded
grep "REF-DIFF" "$1" | grep -v "| ERR" | perl -ne 'm/\[(\w+)\]/ or next; $l=$1; @c = m/\b(i8|i16|i32|i64|f32|f64|b|s|d|ts|tn|dec|dec15|ab|a|if|pl|pdec|pts|ptn|pb|ps|pd|pi|pi8|pf)\b/; $k="$c[0] $l"; $n{$k}++; $ex{$k}//=substr($_,12,140); END{ for (sort keys %n) { chomp $ex{$_}; print "$n{$_}\t$_\t$ex{$_}\n" } }'
