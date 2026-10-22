#!/usr/bin/env python3
"""Rewrite the MANIFEST block of a watchface main.lua with size + adler32 of the
packaged files (the same arithmetic the Lua code performs on the band).
usage: gen_manifest.py <watchface app/lua dir> <file> [<file> ...]"""
import re, sys, zlib, os
d, files = sys.argv[1], sys.argv[2:]
rows = []
for f in files:
    b = open(os.path.join(d, f), 'rb').read()
    a = zlib.adler32(b) & 0xffffffff
    rows.append('    ["%s"] = { size = %d, adler = "%08x" },' % (f, len(b), a))
p = os.path.join(d, 'main.lua')
s = open(p).read()
new = '-- BEGIN MANIFEST (rewritten by tools/mb10p/gen_manifest.py; size + adler32 of each packaged file)\nlocal MANIFEST = {\n' + '\n'.join(rows) + '\n}\n-- END MANIFEST'
s2, n = re.subn(r'-- BEGIN MANIFEST.*?-- END MANIFEST', lambda m: new, s, flags=re.S)
assert n == 1, 'manifest markers not found'
open(p, 'w').write(s2)
print('\n'.join(rows))
