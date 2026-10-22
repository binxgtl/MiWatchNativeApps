#!/usr/bin/env python3
"""Inspect / set the watchface ID inside an EasyFace .face package
(Smart Band 10 Pro, DeviceType 567, EasyFace v4.23 output).

The layout below was derived from two real EasyFace v4.23 outputs (Hello.face,
Calc safe.face); every byte of both files is accounted for and there is no
checksum or signature:

  0x000 u32  magic 0x1234A55A
  0x020 u32  E = end of the file-entry region (repeated at 0x0AC)
  0x028 64 B watchface ID, ASCII decimal, NUL padded  <- the only field `set` changes
  0x068 68 B title (the Screen Title of module.fprj), NUL padded
  0x0D8 u32  number of packaged files N
  0x110      table of 16-byte records (u32 type, u32 0, u32 offset, u32 size),
             N records + one terminator record (offset 0, size 0)
  offset     file entry: u32 (content size | name length << 24), 16 zero bytes,
             name, content; entries are 4-byte aligned and end exactly at E
  E          u32 0, u16 width, u16 height, u32 w*h*4, then the raw preview

Anything that does not match this layout is refused: the tool never patches a
file it does not fully understand. `set` writes a NEW file and re-reads it to
prove that only the ID bytes differ.

usage:
  face_id.py show  FILE.face
  face_id.py check FILE.face --id 193824672 [--title NativeMgr]
  face_id.py set   IN.face OUT.face --id 193824672 --title NativeMgr [--registry face_ids.tsv]
  face_id.py extract FILE.face DIR          (write the packaged files, for checksums)
"""
import argparse, hashlib, os, struct, sys

MAGIC = 0x1234A55A
ID_OFF, ID_LEN = 0x28, 64
TITLE_OFF, TITLE_LEN = 0x68, 68
END_OFF, END_OFF2, COUNT_OFF, TABLE_OFF = 0x20, 0xAC, 0xD8, 0x110
SCREEN = (336, 480)
REGISTRY = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'face_ids.tsv')


class FaceError(Exception):
    pass


def _cstr(b, what):
    raw = b.split(b'\0', 1)[0]
    if b[len(raw):].strip(b'\0'):
        raise FaceError('%s field has data after its NUL terminator' % what)
    return raw


def parse(data):
    """Validate the whole file; return a dict describing it."""
    if len(data) < TABLE_OFF + 32:
        raise FaceError('file too small (%d bytes)' % len(data))
    magic, = struct.unpack_from('<I', data, 0)
    if magic != MAGIC:
        raise FaceError('bad magic 0x%08x (want 0x%08x)' % (magic, MAGIC))
    end, end2 = struct.unpack_from('<I', data, END_OFF)[0], struct.unpack_from('<I', data, END_OFF2)[0]
    if end != end2 or not (TABLE_OFF < end < len(data)):
        raise FaceError('entry-region end 0x%x / 0x%x inconsistent' % (end, end2))
    face_id = _cstr(data[ID_OFF:ID_OFF + ID_LEN], 'ID')
    if not face_id or not face_id.isdigit():
        raise FaceError('ID field is not ASCII decimal: %r' % face_id)
    title = _cstr(data[TITLE_OFF:TITLE_OFF + TITLE_LEN], 'title')
    count, = struct.unpack_from('<I', data, COUNT_OFF)
    if not 1 <= count <= 64:
        raise FaceError('implausible file count %d' % count)
    first = TABLE_OFF + 16 * (count + 1)
    entries, expect_off = [], first
    for i in range(count):
        typ, zero, off, size = struct.unpack_from('<IIII', data, TABLE_OFF + 16 * i)
        if zero != 0 or off != expect_off or size < 21 or off + size > end:
            raise FaceError('record %d inconsistent (type 0x%x off 0x%x size 0x%x, want off 0x%x)' % (i, typ, off, size, expect_off))
        hdr, = struct.unpack_from('<I', data, off)
        clen, nlen = hdr & 0xFFFFFF, hdr >> 24
        if data[off + 4:off + 20].strip(b'\0') or 20 + nlen + clen != size or nlen == 0:
            raise FaceError('file entry %d header inconsistent' % i)
        name = data[off + 20:off + 20 + nlen].decode('ascii', 'strict')
        content = data[off + 20 + nlen:off + size]
        entries.append({'name': name, 'type': typ, 'offset': off, 'size': size, 'content': content})
        expect_off = (off + size + 3) & ~3
    term = struct.unpack_from('<IIII', data, TABLE_OFF + 16 * count)
    if term[2] != 0 or term[3] != 0:
        raise FaceError('table terminator missing')
    if expect_off != end:
        raise FaceError('entries end at 0x%x, header says 0x%x' % (expect_off, end))
    z, w, h, psize = struct.unpack_from('<IHHI', data, end)
    if z != 0 or (w, h) != SCREEN or psize != w * h * 4 or end + 12 + psize != len(data):
        raise FaceError('preview block inconsistent (%dx%d, %d bytes, file %d)' % (w, h, psize, len(data)))
    return {'id': face_id.decode(), 'title': title.decode('utf-8', 'replace'), 'end': end,
            'count': count, 'entries': entries, 'preview': (w, h), 'size': len(data)}


def load_registry(path):
    reg = {}
    if not os.path.exists(path):
        return reg
    for line in open(path, encoding='utf-8'):
        if not line.strip() or line.startswith('#') or line.startswith('id\t'):
            continue
        cols = line.rstrip('\n').split('\t')
        reg[cols[0]] = cols[1] if len(cols) > 1 else ''
    return reg


def cmd_show(a):
    data = open(a.file, 'rb').read()
    info = parse(data)
    print('file    %s (%d bytes, sha256 %s)' % (a.file, info['size'], hashlib.sha256(data).hexdigest()))
    print('id      %s' % info['id'])
    print('title   %s' % info['title'])
    print('preview %dx%d' % info['preview'])
    for e in info['entries']:
        print('  %-40s %7d bytes  sha256 %s' % (e['name'], len(e['content']), hashlib.sha256(e['content']).hexdigest()))
    return 0


def cmd_check(a):
    info = parse(open(a.file, 'rb').read())
    ok = info['id'] == a.id and (a.title is None or info['title'] == a.title)
    print('%s id=%s title=%s' % ('OK  ' if ok else 'FAIL', info['id'], info['title']))
    return 0 if ok else 1


def cmd_set(a):
    if not a.id.isdigit() or len(a.id) != 9:
        raise FaceError('new ID must be 9 decimal digits (the length of the IDs proven on the band)')
    if os.path.abspath(a.inp) == os.path.abspath(a.out):
        raise FaceError('refusing to patch in place; give a different output file')
    data = open(a.inp, 'rb').read()
    info = parse(data)
    if info['title'] != a.title:
        raise FaceError('title in package is %r, expected %r: wrong file?' % (info['title'], a.title))
    reg = load_registry(a.registry)
    owner = reg.get(a.id)
    if owner is not None and owner != a.title:
        raise FaceError('ID %s is registered to %r in %s' % (a.id, owner, a.registry))
    if owner is None:
        print('warning: ID %s not in %s; add it so no other package reuses it' % (a.id, a.registry))
    new = bytearray(data)
    field = a.id.encode('ascii').ljust(ID_LEN, b'\0')
    new[ID_OFF:ID_OFF + ID_LEN] = field
    new = bytes(new)
    check = parse(new)
    diff = [i for i in range(len(data)) if data[i] != new[i]]
    if check['id'] != a.id or len(new) != len(data) or any(not (ID_OFF <= i < ID_OFF + ID_LEN) for i in diff):
        raise FaceError('self-check failed: bytes outside the ID field would change')
    with open(a.out, 'wb') as f:
        f.write(new)
    again = parse(open(a.out, 'rb').read())
    print('OK  %s: id %s -> %s (%d bytes changed, all inside 0x%x..0x%x), sha256 %s'
          % (a.out, info['id'], again['id'], len(diff), ID_OFF, ID_OFF + ID_LEN - 1, hashlib.sha256(new).hexdigest()))
    return 0


def cmd_extract(a):
    info = parse(open(a.file, 'rb').read())
    for e in info['entries']:
        p = os.path.join(a.dir, e['name'])
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f:
            f.write(e['content'])
        print('%s %s' % (hashlib.sha256(e['content']).hexdigest(), e['name']))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('show'); s.add_argument('file')
    s = sub.add_parser('check'); s.add_argument('file'); s.add_argument('--id', required=True); s.add_argument('--title')
    s = sub.add_parser('set'); s.add_argument('inp'); s.add_argument('out'); s.add_argument('--id', required=True)
    s.add_argument('--title', required=True); s.add_argument('--registry', default=REGISTRY)
    s = sub.add_parser('extract'); s.add_argument('file'); s.add_argument('dir')
    a = ap.parse_args(argv)
    try:
        return {'show': cmd_show, 'check': cmd_check, 'set': cmd_set, 'extract': cmd_extract}[a.cmd](a)
    except FaceError as e:
        print('REFUSED: %s' % e, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
