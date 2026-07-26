#!/bin/sh
# Validates the JavaScript embedded in ContentFilter.swift.
#
# There is no test target, and `node --check` only catches syntax errors. An
# init-time throw (a bad assignment, an out-of-scope reference) parses fine and
# still kills the MutationObserver before it starts, silently disabling the
# whole filter. The runtime proof below is what catches that class of bug.
set -e

cd "$(dirname "$0")"
SRC=../ios/BetterInstagram/ContentFilter.swift
OUT=build
mkdir -p "$OUT"

if [ ! -d node_modules ]; then
  echo "installing jsdom..."
  npm install --silent
fi

python3 extract-userscript.py "$SRC" script "$OUT/filter.js"
python3 extract-userscript.py "$SRC" harvestScript "$OUT/harvest.js"
python3 extract-userscript.py "$SRC" densityScript "$OUT/density.js"

node --check "$OUT/filter.js"
echo "syntax OK: script"

# harvestScript and densityScript are callAsyncJavaScript bodies: top-level
# await and return only parse inside an async function.
for s in harvest density; do
  { echo '(async function(){'; cat "$OUT/$s.js"; echo '})'; } > "$OUT/$s.wrapped.js"
  node --check "$OUT/$s.wrapped.js"
  echo "syntax OK: $s"
done

echo
node userscript-init-test.js "$OUT/filter.js"
