#!/usr/bin/env python3
"""Build the MB10 Pro (fw 3.201.026) Lua watchface packages without EasyFace.

    python3 tools/mb10p/build_faces.py [--out DIR] [--target NAME ...]

Default output: build/faces/3.201.026/<target>_<id>.face, plus SHA256SUMS
and BUILD_INFO.txt. Targets come from tools/mb10p/face_targets.tsv; the ID
must be registered in tools/mb10p/face_ids.tsv and the package title is the
registered title. Packing is done by face_pack.py, which only accepts the
DeviceType 567 / single Lua widget project shape (see its docstring).

Fail-closed, nothing is ever overwritten:
  - the output directory must not exist; everything is built in a staging
    directory next to it and renamed into place only if every target passed;
  - every .elf in a project must equal the dist/mb10p-3.201.026 copy listed
    in its SHA256SUMS (name without the _3.201.026 suffix);
  - links, hidden files and sub-directories in app/lua are refused;
  - each output is re-parsed and its files and preview compared with the
    sources;
  - a target with hw_sha256 must reproduce that hardware-confirmed file
    byte for byte (canary for packer or source drift).

EasyFace stays the fallback: docs/mb10p-3.201.026/EASYFACE_BUILD.md.
"""
import argparse, hashlib, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import face_id, face_pack                                   # noqa: E402

FW = '3.201.026'


class BuildError(Exception):
    pass


def sha(b):
    return hashlib.sha256(b).hexdigest()


def read_tsv(path, ncols):
    rows = []
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        if n == 1 or not line.strip() or line.startswith('#'):
            continue
        cols = line.rstrip('\n').split('\t')
        if len(cols) != ncols:
            raise BuildError('%s:%d: want %d tab-separated columns, got %d' % (path, n, ncols, len(cols)))
        rows.append(cols)
    return rows


def dist_hashes(root):
    d = os.path.join(root, 'dist', 'mb10p-' + FW)
    out = {}
    for cols in (l.split() for l in open(os.path.join(d, 'SHA256SUMS'))):
        if len(cols) == 2 and '/' not in cols[1]:              # experimental/ ELFs are never packaged
            data = open(os.path.join(d, cols[1]), 'rb').read()
            if sha(data) != cols[0]:
                raise BuildError('dist/%s does not match its SHA256SUMS' % cols[1])
            out[cols[1]] = cols[0]
    return out


def project_dir(root, rel):
    if not re.fullmatch(r'mb10pro/wf_native_[a-z0-9_]+', rel):
        raise BuildError('%s: project must be mb10pro/wf_native_<name>' % rel)
    p = os.path.join(root, rel)
    for q in (p, os.path.join(p, 'app'), os.path.join(p, 'app', 'lua'), os.path.join(p, 'images')):
        if os.path.islink(q) or not os.path.isdir(q):
            raise BuildError('%s: missing or not a plain directory' % os.path.relpath(q, root))
    return p


def stage(root, t, title, dist, dest):
    """Copy the target's sources into dest as one project; return the staged file map."""
    fprj_dir, lua_dir = project_dir(root, t['fprj_dir']), project_dir(root, t['lua_dir'])
    src = os.path.join(fprj_dir, 'module.fprj')
    if os.path.islink(src):
        raise BuildError('%s/module.fprj is a link' % t['fprj_dir'])
    fprj = open(src, 'rb').read().decode('utf-8-sig', 'strict')
    screens = re.findall(r'<Screen\s+Title="([^"]*)"\s+Bitmap="([A-Za-z0-9_\-][A-Za-z0-9_.\-]*\.png)"\s*>', fprj)
    if len(screens) != 1 or fprj.count('<Screen') != 1:
        raise BuildError('%s/module.fprj: need exactly one <Screen Title=".." Bitmap="x.png">' % t['fprj_dir'])
    if '"' in title or '<' in title or '&' in title:
        raise BuildError('registered title %r cannot be written into module.fprj' % title)
    fprj = re.sub(r'(<Screen\s+Title=")[^"]*(")', lambda m: m.group(1) + title + m.group(2), fprj, count=1)
    bitmap = screens[0][1]
    os.makedirs(os.path.join(dest, 'app', 'lua'))
    os.makedirs(os.path.join(dest, 'images'))
    with open(os.path.join(dest, 'module.fprj'), 'xb') as f:
        f.write(fprj.encode('utf-8'))
    png = os.path.join(fprj_dir, 'images', bitmap)
    if os.path.islink(png) or not os.path.isfile(png):
        raise BuildError('%s/images/%s missing or a link' % (t['fprj_dir'], bitmap))
    shutil.copyfile(png, os.path.join(dest, 'images', bitmap))
    files = {}
    lua = os.path.join(lua_dir, 'app', 'lua')
    for n in sorted(os.listdir(lua)):
        p = os.path.join(lua, n)
        if os.path.islink(p) or not os.path.isfile(p):
            raise BuildError('%s/app/lua/%s: not a plain file' % (t['lua_dir'], n))
        data = open(p, 'rb').read()
        if n.endswith('.elf'):
            base = n.replace('_' + FW + '.elf', '.elf')
            if base not in dist:
                raise BuildError('%s/app/lua/%s: no dist/mb10p-%s/%s to check it against' % (t['lua_dir'], n, FW, base))
            if sha(data) != dist[base]:
                raise BuildError('%s/app/lua/%s differs from dist/mb10p-%s/%s (run build_mb10p.sh / verify_all.sh)'
                                 % (t['lua_dir'], n, FW, base))
        with open(os.path.join(dest, 'app', 'lua', n), 'xb') as f:
            f.write(data)
        files['lua/' + n] = data
    return files, os.path.join(dest, 'images', bitmap)


def verify_output(path, t, title, files, png):
    data = open(path, 'rb').read()
    info = face_id.parse(data)
    if info['id'] != t['id'] or info['title'] != title:
        raise BuildError('%s: id/title %s/%r, want %s/%r' % (path, info['id'], info['title'], t['id'], title))
    got = {e['name']: e['content'] for e in info['entries']}
    if got != files:
        raise BuildError('%s: packaged files differ from the sources' % path)
    if data[info['end'] + 12:] != face_pack.read_png_bgra(png):
        raise BuildError('%s: preview differs from %s' % (path, png))
    if t['hw_sha256'] != '-' and sha(data) != t['hw_sha256']:
        raise BuildError('%s: sha256 %s is not the hardware-confirmed %s; the packer or the sources of %s changed'
                         % (path, sha(data), t['hw_sha256'], t['target']))
    return data


def git_rev(root):
    try:
        rev = subprocess.run(['git', '-C', root, 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(['git', '-C', root, 'status', '--porcelain', '--', 'mb10pro', 'dist', 'tools/mb10p'],
                               capture_output=True, text=True, check=True).stdout.strip()
        return rev + (' (with uncommitted changes)' if dirty else '')
    except (OSError, subprocess.CalledProcessError):
        return 'unknown (not a git checkout)'


def build(root, out, names):
    tools = os.path.join(root, 'tools', 'mb10p')
    targets = [dict(zip(('target', 'id', 'fprj_dir', 'lua_dir', 'hw_sha256', 'hardware'), r))
               for r in read_tsv(os.path.join(tools, 'face_targets.tsv'), 6)]
    known = [t['target'] for t in targets]
    if len(set(known)) != len(known) or len({t['id'] for t in targets}) != len(targets):
        raise BuildError('face_targets.tsv: duplicate target name or ID')
    for n in names:
        if n not in known:
            raise BuildError('unknown target %r (have: %s)' % (n, ', '.join(known)))
    chosen = [t for t in targets if not names or t['target'] in names]
    reg = face_id.load_registry(os.path.join(tools, 'face_ids.tsv'))
    for t in chosen:
        if not (t['id'].isdigit() and len(t['id']) == 9) or t['id'] not in reg:
            raise BuildError('%s: ID %s is not registered in face_ids.tsv' % (t['target'], t['id']))
        if t['hw_sha256'] != '-' and not re.fullmatch(r'[0-9a-f]{64}', t['hw_sha256']):
            raise BuildError('%s: hw_sha256 must be 64 hex digits or -' % t['target'])
    dist = dist_hashes(root)

    out = os.path.abspath(out)
    if os.path.lexists(out):
        raise BuildError('%s exists; nothing is overwritten (remove it yourself or use --out)' % out)
    parent = os.path.dirname(out)
    os.makedirs(parent, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='.' + os.path.basename(out) + '.staging-', dir=parent)
    try:
        res = os.path.join(tmp, 'out')
        os.mkdir(res)
        sums, info = [], ['MB10 Pro %s Lua watchfaces packed by tools/mb10p/face_pack.py (not EasyFace)' % FW,
                          'source: ' + git_rev(root), '']
        for t in chosen:
            title = reg[t['id']]
            files, png = stage(root, t, title, dist, os.path.join(tmp, 'proj_' + t['target']))
            name = '%s_%s.face' % (t['target'], t['id'])
            path = os.path.join(res, name)
            rc = face_pack.main([os.path.join(tmp, 'proj_' + t['target']), path, '--id', t['id']])
            if rc != 0:
                raise BuildError('%s: face_pack refused the project' % t['target'])
            data = verify_output(path, t, title, files, png)
            sums.append('%s  %s' % (sha(data), name))
            info += ['%s  id=%s  title=%s  %d bytes' % (name, t['id'], title, len(data)),
                     '  sources: %s (module.fprj, preview) + %s (app/lua)' % (t['fprj_dir'], t['lua_dir']),
                     '  files: ' + ', '.join(sorted(files)),
                     '  hardware: ' + t['hardware'], '']
        with open(os.path.join(res, 'SHA256SUMS'), 'x') as f:
            f.write('\n'.join(sums) + '\n')
        with open(os.path.join(res, 'BUILD_INFO.txt'), 'x') as f:
            f.write('\n'.join(info))
        if os.path.lexists(out):
            raise BuildError('%s appeared during the build; not replaced' % out)
        os.rename(res, out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out, sums


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--root', default=os.path.dirname(os.path.dirname(HERE)), help=argparse.SUPPRESS)
    ap.add_argument('--out', default=None, help='output directory (must not exist); default build/faces/%s' % FW)
    ap.add_argument('--target', action='append', default=[], help='build only this target (repeatable)')
    a = ap.parse_args(argv)
    out = a.out or os.path.join(a.root, 'build', 'faces', FW)
    try:
        out, sums = build(a.root, out, a.target)
    except (BuildError, face_pack.PackError, face_id.FaceError, OSError, UnicodeDecodeError) as e:
        print('BUILD REFUSED: %s' % e, file=sys.stderr)
        return 2
    print('BUILT %d package(s) in %s' % (len(sums), out))
    for s in sums:
        print('  ' + s)
    return 0


if __name__ == '__main__':
    sys.exit(main())
