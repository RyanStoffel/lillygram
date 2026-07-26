#!/usr/bin/env python3
"""Extract a Swift multiline-string constant from ContentFilter.swift as real JS."""
import re, sys

path, name, out = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()

m = re.search(r'static let %s = """\n(.*?)\n\s*"""' % re.escape(name), src, re.S)
if not m:
    sys.exit("could not find %s" % name)
body = m.group(1)

# Swift multiline strings strip the indentation of the closing delimiter (4 spaces here).
lines = [l[4:] if l.startswith("    ") else l for l in body.split("\n")]
js = "\n".join(lines)

# Undo Swift string escapes. \\ -> \ is the only one used in these scripts
# (regex backslashes are doubled per AGENTS.md); guard against interpolation.
if re.search(r'(?<!\\)\\\(', js):
    sys.exit("string interpolation found in %s - extractor would be wrong" % name)
js = js.replace("\\\\", "\\").replace('\\"', '"')

open(out, "w").write(js)
print("wrote %s (%d bytes, %d lines)" % (out, len(js), js.count("\n") + 1))
