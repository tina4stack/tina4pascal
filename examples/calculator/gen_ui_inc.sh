#!/usr/bin/env bash
# Regenerate calculator_ui.inc (an embedded copy of calculator.html) so the
# built binary is standalone. Run after editing calculator.html:
#   bash gen_ui_inc.sh
set -eu
cd "$(dirname "$0")"
IN=calculator.html
OUT=calculator_ui.inc
{
  echo "{ Generated from calculator.html by gen_ui_inc.sh — do not edit by hand."
  echo "  Embeds the UI so the binary ships standalone (no external asset). }"
  echo "const CALC_HTML ="
  n=$(wc -l < "$IN")
  i=0
  while IFS= read -r line || [ -n "$line" ]; do
    i=$((i+1))
    esc=${line//\'/\'\'}            # ' -> '' for Pascal string literals
    if [ "$i" -lt "$n" ]; then
      printf "  '%s'#10 +\n" "$esc"
    else
      printf "  '%s'#10;\n" "$esc"
    fi
  done < "$IN"
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
