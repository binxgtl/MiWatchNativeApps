#!/usr/bin/env python3
"""Offline test for tools/mb10p/face_pack.py.

    python3 tools/mb10p/test_face_pack.py [REFERENCE_DIR]

Always: packs a synthetic project and checks layout, determinism and the
refusals. With REFERENCE_DIR containing EasyFace-built Hello.face and
Calc_safe.face (not in the repo), also rebuilds both from the sources at
commit 6d9ad0f and requires byte-identical output.
"""
import os, shutil, struct, subprocess, sys, tempfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import face_id, face_pack                               # noqa: E402

FPRJ = ('<?xml version="1.0" encoding="utf-16" ?>\n<FaceProject DeviceType="567">\n'
        '    <Screen Title="%s" Bitmap="preview.png">\n'
        '        <Widget Shape="34" Name="app_lua%%2Fmain.lua" X="0" Y="0" Width="336" Height="480" Alpha="0" Visible_Src="0" />\n'
        '    </Screen>\n</FaceProject>\n')


def png(w, h, rgba=True):
    bpp = 4 if rgba else 3
    rows = b''.join(b'\x00' + bytes((x * 7 + y) & 255 for x in range(w * bpp)) for y in range(h))
    def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6 if rgba else 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def project(d, title='T', fprj=None, files=None, preview=None):
    os.makedirs(os.path.join(d, 'app', 'lua'))
    os.makedirs(os.path.join(d, 'images'))
    open(os.path.join(d, 'module.fprj'), 'w').write(fprj or FPRJ % title)
    open(os.path.join(d, 'images', 'preview.png'), 'wb').write(preview if preview is not None else png(336, 480))
    for n, c in (files or {'main.lua': b'-- x\n', 'a.elf': b'\x7fELF' + b'\1' * 33}).items():
        open(os.path.join(d, 'app', 'lua', n), 'wb').write(c)


def pack(d, out, id_='193824699'):
    r = subprocess.run([sys.executable, os.path.join(HERE, 'face_pack.py'), d, out, '--id', id_], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main():
    fails, total = [], [0]
    def check(name, cond, detail=''):
        total[0] += 1
        print(('PASS ' if cond else 'FAIL ') + name + ('' if cond else '  [' + str(detail)[:200] + ']'))
        if not cond: fails.append(name)
    t = tempfile.mkdtemp(prefix='facepack_')
    project(t + '/p')
    rc, out = pack(t + '/p', t + '/a.face')
    rc2, _ = pack(t + '/p', t + '/b.face')
    a = open(t + '/a.face', 'rb').read() if rc == 0 else b''
    check('synthetic project packs', rc == 0, out)
    check('output passes the independent layout parser', rc == 0 and face_id.parse(a)['id'] == '193824699')
    check('deterministic', rc2 == 0 and a == open(t + '/b.face', 'rb').read())
    info = face_id.parse(a) if a else {'entries': []}
    check('files in name order, script recorded in the terminator',
          [e['name'] for e in info['entries']] == ['lua/a.elf', 'lua/main.lua']
          and struct.unpack_from('<I', a, face_id.TABLE_OFF + 32)[0] == 0x05000001)
    rc, out = pack(t + '/p', t + '/a.face')
    check('never overwrites an existing file', rc == 2 and 'exists' in out, out)
    bad = {
        'wrong DeviceType': dict(fprj=(FPRJ % 'T').replace('567', '566')),
        'second widget': dict(fprj=(FPRJ % 'T').replace('</Screen>', '<Widget Shape="30" Name="x" />\n</Screen>')),
        'no main.lua': dict(files={'other.lua': b'x'}),
        'odd file name': dict(files={'main.lua': b'x', 'a b.png': b'x'}),
        'preview 320x480': dict(preview=png(320, 480)),
        'preview not a PNG': dict(preview=b'GIF89a'),
        'empty title': dict(title=''),
    }
    for i, (name, kw) in enumerate(bad.items()):
        d = '%s/bad%d' % (t, i)
        project(d, **kw)
        rc, out = pack(d, d + '.face')
        check('refuses %s' % name, rc == 2 and not os.path.exists(d + '.face'), out)
    rc, out = pack(t + '/p', t + '/c.face', '12345')
    check('refuses an ID that is not 9 digits', rc == 2, out)
    project(t + '/rgb', preview=png(336, 480, rgba=False))
    rc, out = pack(t + '/rgb', t + '/rgb.face')
    check('RGB preview accepted as opaque (not yet compared with EasyFace)', rc == 0, out)

    if len(sys.argv) > 1:                       # byte comparison with real EasyFace outputs
        ref = sys.argv[1]
        src = os.path.join(t, 'src')
        os.makedirs(src)
        subprocess.run('git -C %s archive 6d9ad0f mb10pro | tar -x -C %s' % (REPO, src), shell=True, check=True)
        m = os.path.join(src, 'mb10pro')
        h = os.path.join(t, 'hello')
        os.makedirs(h + '/app/lua'); os.makedirs(h + '/images')
        shutil.copy(m + '/wf_native_hello/module.fprj', h)
        shutil.copy(m + '/wf_native_hello/images/preview.png', h + '/images')
        for n in ('main.lua', 'mb10p_hello_3.201.026.elf'):
            shutil.copy(m + '/wf_native_hello_test/app/lua/' + n, h + '/app/lua')
        for d, refname in ((h, 'Hello.face'), (m + '/wf_native_calc_safe', 'Calc_safe.face')):
            out_f = os.path.join(t, refname)
            rc, out = pack(d, out_f, '167210065')
            same = rc == 0 and open(out_f, 'rb').read() == open(os.path.join(ref, refname), 'rb').read()
            check('byte-identical to EasyFace v4.23 %s' % refname, same, out)
    print('ALL %d CHECKS OK' % total[0] if not fails else 'FAILURES: %d of %d' % (len(fails), total[0]))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
