#!/usr/bin/env python3
"""Offline test for tools/mb10p/face_id.py on a synthetic package built with
the layout documented in face_id.py (real EasyFace outputs are not committed).
usage: python3 tools/mb10p/test_face_id.py"""
import os, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, 'face_id.py')


def build(face_id=b'167210065', title=b'NativeMgr', files=None, preview=(336, 480)):
    files = files or [('lua/main.lua', b'-- lua\n' * 50), ('lua/x.elf', b'\x7fELF' + b'\0' * 1000)]
    n = len(files)
    first = 0x110 + 16 * (n + 1)
    body, recs, off = b'', b'', first
    for i, (name, content) in enumerate(files):
        nm = name.encode()
        entry = struct.pack('<I', len(content) | (len(nm) << 24)) + b'\0' * 16 + nm + content
        recs += struct.pack('<IIII', 0x05000000 | i, 0, off, len(entry))
        pad = (-len(entry)) % 4
        body += entry + b'\0' * pad
        off += len(entry) + pad
    end = off
    hdr = bytearray(first)
    struct.pack_into('<I', hdr, 0, 0x1234A55A)
    struct.pack_into('<I', hdr, 0x10, 0x800)
    struct.pack_into('<I', hdr, 0x1C, 1)
    struct.pack_into('<I', hdr, 0x20, end)
    hdr[0x28:0x28 + len(face_id)] = face_id
    hdr[0x68:0x68 + len(title)] = title
    struct.pack_into('<I', hdr, 0xAC, end)
    struct.pack_into('<I', hdr, 0xD8, n)
    hdr[0x110:0x110 + len(recs)] = recs
    w, h = preview
    return bytes(hdr) + body + struct.pack('<IHHI', 0, w, h, w * h * 4) + b'\x11' * (w * h * 4)


def run(*args):
    r = subprocess.run([sys.executable, TOOL] + list(args), capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main():
    fails, total = [], [0]
    def check(name, cond, detail=''):
        total[0] += 1
        print(('PASS ' if cond else 'FAIL ') + name + ('' if cond else '  [' + detail.strip()[:200] + ']'))
        if not cond:
            fails.append(name)
    d = tempfile.mkdtemp(prefix='faceid_')
    reg = os.path.join(d, 'reg.tsv')
    open(reg, 'w').write('id\ttitle\n167210065\tHello\n193824671\tCalc safe\n193824672\tNativeMgr\n')
    good = os.path.join(d, 'm.face'); open(good, 'wb').write(build())
    rc, out = run('show', good)
    check('show parses a well-formed package', rc == 0 and 'id      167210065' in out and 'lua/x.elf' in out, out)
    outp = os.path.join(d, 'out.face')
    rc, out = run('set', good, outp, '--id', '193824672', '--title', 'NativeMgr', '--registry', reg)
    check('set writes a new file with the new ID', rc == 0 and os.path.exists(outp), out)
    a, b = open(good, 'rb').read(), open(outp, 'rb').read()
    diff = [i for i in range(len(a)) if a[i] != b[i]]
    check('only bytes inside 0x28..0x67 change', len(a) == len(b) and diff and all(0x28 <= i < 0x68 for i in diff), str(diff[:10]))
    rc, out = run('check', outp, '--id', '193824672', '--title', 'NativeMgr')
    check('check confirms the new ID', rc == 0, out)
    rc, out = run('check', good, '--id', '193824672')
    check('check fails on the old ID', rc == 1, out)
    rc, out = run('set', good, os.path.join(d, 'o2.face'), '--id', '193824671', '--title', 'NativeMgr', '--registry', reg)
    check('refuses an ID registered to another package', rc == 2 and 'registered' in out, out)
    rc, out = run('set', good, os.path.join(d, 'o3.face'), '--id', '1938246', '--title', 'NativeMgr', '--registry', reg)
    check('refuses an ID that is not 9 digits', rc == 2, out)
    rc, out = run('set', good, os.path.join(d, 'o4.face'), '--id', '193824672', '--title', 'Hello', '--registry', reg)
    check('refuses a package with another title', rc == 2 and 'title' in out, out)
    rc, out = run('set', good, good, '--id', '193824672', '--title', 'NativeMgr', '--registry', reg)
    check('refuses to patch in place', rc == 2, out)
    bad_cases = {
        'bad magic': lambda x: b'\0\0\0\0' + x[4:],
        'truncated': lambda x: x[:-10],
        'end offsets disagree': lambda x: x[:0xAC] + struct.pack('<I', 0x999) + x[0xB0:],
        'non-digit ID': lambda x: x[:0x28] + b'16721006X' + x[0x31:],
        'garbage after ID terminator': lambda x: x[:0x40] + b'Z' + x[0x41:],
        'entry header corrupt': lambda x: x[:0x140 + 4] + b'\x01' + x[0x140 + 5:],
        'wrong preview size': lambda x: build(preview=(320, 480)),
    }
    for name, f in bad_cases.items():
        p = os.path.join(d, 'bad.face')
        open(p, 'wb').write(f(build()))
        rc, out = run('set', p, os.path.join(d, 'bad_out.face'), '--id', '193824672', '--title', 'NativeMgr', '--registry', reg)
        check('refuses %s' % name, rc == 2 and 'REFUSED' in out and not os.path.exists(os.path.join(d, 'bad_out.face')), out)
    print('ALL %d CHECKS OK' % total[0] if not fails else 'FAILURES: %d of %d' % (len(fails), total[0]))
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())
