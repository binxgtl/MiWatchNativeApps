#!/usr/bin/env python3
"""Offline test for tools/mb10p/build_faces.py (the .face build entry point).

    python3 tools/mb10p/test_build_faces.py

Builds the real targets twice (deterministic, hello_py equal to the file that
passed on the band), then runs the refusals on throw-away copies of the
sources. Nothing in the repository is modified.
"""
import hashlib, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import face_id                                              # noqa: E402

HW_HELLO_PY = '0e2491ebcd77ef8cb6294b326008a90b25d912510acbce2bcafe27d7e3078c50'
HW_CALC_DEC = 'abcb50dca04f2ef2407f43995ce6b6761baa16ea16ea0ee55566026d7f127f8f'


def run(*args, root=None):
    cmd = [sys.executable, os.path.join(HERE, 'build_faces.py')] + list(args)
    if root:
        cmd += ['--root', root]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def fake_root(t, name):
    """Minimal copy of the inputs build_faces.py reads (including the scripts' registry files)."""
    r = os.path.join(t, name)
    for d in ('mb10pro/wf_native_hello', 'mb10pro/wf_native_hello_test', 'mb10pro/wf_native_calc_safe',
              'mb10pro/wf_native_manager', 'mb10pro/wf_native_calc_dec', 'dist/mb10p-3.201.026'):
        shutil.copytree(os.path.join(REPO, d), os.path.join(r, d), symlinks=True)
    os.makedirs(os.path.join(r, 'tools', 'mb10p'))
    for f in ('face_targets.tsv', 'face_ids.tsv'):
        shutil.copy(os.path.join(HERE, f), os.path.join(r, 'tools', 'mb10p', f))
    return r


def main():
    fails, total = [], [0]
    def check(name, cond, detail=''):
        total[0] += 1
        print(('PASS ' if cond else 'FAIL ') + name + ('' if cond else '  [' + str(detail)[-300:] + ']'))
        if not cond: fails.append(name)
    t = tempfile.mkdtemp(prefix='buildfaces_')

    rc, out = run('--out', t + '/a')
    names = sorted(f for f in os.listdir(t + '/a')) if rc == 0 else []
    check('all targets build', rc == 0 and names == ['BUILD_INFO.txt', 'SHA256SUMS', 'calc_dec_193824674.face', 'calc_safe_193824671.face',
                                                     'hello_py_193824675.face', 'native_mgr_193824672.face'], out)
    hp = open(t + '/a/hello_py_193824675.face', 'rb').read() if rc == 0 else b''
    check('hello_py equals the package that passed on the band (sha256 %s..)' % HW_HELLO_PY[:12],
          hashlib.sha256(hp).hexdigest() == HW_HELLO_PY)
    cd = open(t + '/a/calc_dec_193824674.face', 'rb').read() if rc == 0 else b''
    check('calc_dec equals the package that passed on the band (sha256 %s..)' % HW_CALC_DEC[:12],
          hashlib.sha256(cd).hexdigest() == HW_CALC_DEC)
    ok = rc == 0
    for line in (open(t + '/a/SHA256SUMS').read().split('\n') if ok else []):
        if line:
            h, n = line.split('  ')
            data = open(os.path.join(t, 'a', n), 'rb').read()
            ok = ok and hashlib.sha256(data).hexdigest() == h and face_id.parse(data)['id'] == n[-14:-5]
    check('SHA256SUMS matches and every package passes face_id.parse with its ID', ok)
    info = open(t + '/a/BUILD_INFO.txt').read() if rc == 0 else ''
    check('BUILD_INFO records the hardware status per target',
          info.count('hardware: PASS 2026-10-23') == 2 and info.count('NOT hardware-tested') == 1 and 'RGB preview' in info)
    rc2, out2 = run('--out', t + '/b')
    same = rc2 == 0 and all(open(os.path.join(t, 'a', n), 'rb').read() == open(os.path.join(t, 'b', n), 'rb').read()
                            for n in names if n.endswith('.face'))
    check('deterministic: a second build is byte-identical', same, out2)
    before = {n: open(os.path.join(t, 'a', n), 'rb').read() for n in names}
    rc, out = run('--out', t + '/a')
    check('refuses an existing output directory and leaves it untouched',
          rc == 2 and 'exists' in out and {n: open(os.path.join(t, 'a', n), 'rb').read() for n in os.listdir(t + '/a')} == before, out)
    rc, out = run('--out', t + '/one', '--target', 'native_mgr')
    check('--target builds only that target', rc == 0 and sorted(os.listdir(t + '/one'))[2:] == ['native_mgr_193824672.face'], out)
    rc, out = run('--out', t + '/x', '--target', 'nope')
    check('refuses an unknown target', rc == 2 and not os.path.exists(t + '/x'), out)

    def refuse(name, mutate, needle, target='hello_py'):
        r = fake_root(t, 'r_' + str(total[0]))
        mutate(r)
        o = os.path.join(t, 'o_' + str(total[0]))
        rc, out = run('--out', o, '--target', target, root=r)
        leftovers = [n for n in os.listdir(t) if '.staging-' in n]
        check('refuses ' + name, rc == 2 and needle in out and not os.path.exists(o) and not leftovers, out)

    def edit(path, old, new):
        def f(r):
            p = os.path.join(r, path)
            s = open(p, 'rb').read()
            assert old in s, (path, old)
            open(p, 'wb').write(s.replace(old, new, 1))
        return f
    L = 'mb10pro/wf_native_hello_test/app/lua/'
    refuse('an embedded ELF that differs from dist/', edit(L + 'mb10p_hello_3.201.026.elf', b'\x7fELF\x01', b'\x7fELF\x02'),
           'differs from dist')
    refuse('an ELF with no dist/ counterpart',
           lambda r: shutil.copy(os.path.join(r, L, 'mb10p_hello_3.201.026.elf'), os.path.join(r, L, 'x_3.201.026.elf')),
           'no dist')
    refuse('a dist/ ELF that does not match dist/SHA256SUMS',
           edit('dist/mb10p-3.201.026/mb10p_hello.elf', b'\x7fELF\x01', b'\x7fELF\x02'), 'SHA256SUMS')
    refuse('a hello_py source change (no longer the hardware-confirmed file)',
           edit(L + 'main.lua', b'Hello', b'Hallo'), 'hardware-confirmed')
    refuse('a calc_dec loader change (no longer the hardware-confirmed file)',
           edit('mb10pro/wf_native_calc_dec/app/lua/main.lua', b'Calc dec ready', b'Calc dec READY'), 'hardware-confirmed',
           target='calc_dec')
    refuse('a symlink in app/lua', lambda r: os.symlink('main.lua', os.path.join(r, L, 'link.lua')), 'not a plain file')
    refuse('a hidden file in app/lua', lambda r: open(os.path.join(r, L, '.x'), 'w').write('x'), 'hidden')
    refuse('an ID missing from face_ids.tsv', edit('tools/mb10p/face_ids.tsv', b'193824675\t', b'193824699\t'),
           'not registered')
    refuse('a project outside mb10pro/wf_native_*',
           edit('tools/mb10p/face_targets.tsv', b'\tmb10pro/wf_native_hello_test\t', b'\tmb10pro/../dist\t'),
           'must be mb10pro/wf_native_')
    refuse('a second Screen in module.fprj',
           edit('mb10pro/wf_native_hello/module.fprj', b'</FaceProject>',
                b'<Screen Title="x" Bitmap="preview.png"></Screen></FaceProject>'), 'exactly one')
    refuse('another DeviceType', edit('mb10pro/wf_native_hello/module.fprj', b'"567"', b'"566"'), 'DeviceType')
    refuse('a second widget', edit('mb10pro/wf_native_hello/module.fprj', b'</Screen>', b'<Widget Shape="30" Name="x" />\n</Screen>'),
           'exactly this widget')
    refuse('a malformed targets row', edit('tools/mb10p/face_targets.tsv', b'\t-\t', b'\t'), 'columns',
           target='calc_safe')
    print('ALL %d CHECKS OK' % total[0] if not fails else 'FAILURES: %d of %d' % (len(fails), total[0]))
    shutil.rmtree(t, ignore_errors=True)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
