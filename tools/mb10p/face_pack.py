#!/usr/bin/env python3
"""Offline .face packer for Lua watchfaces on Smart Band 10 Pro (EasyFace
DeviceType 567), the layout EasyFace v4.23 writes for the native-app
loaders in mb10pro/wf_native_*. Python 3 standard library only.

    face_pack.py PROJECT_DIR OUT.face --id 193824672

PROJECT_DIR is an EasyFace project of the shape used here:
    module.fprj        <FaceProject DeviceType="567"><Screen Title=".." Bitmap="preview.png">
                       with exactly one Widget Shape="34" Name="app_lua%2Fmain.lua" 0,0,336x480
    images/<Bitmap>    336x480 PNG, 8-bit RGB or RGBA, not interlaced
    app/lua/*          files packed as "lua/<name>" (no sub-directories)

Anything else is refused: this is NOT a general EasyFace replacement. The
byte layout (see face_id.py) was taken from two EasyFace v4.23 outputs;
`face_pack.py --selftest DIR` rebuilds them from their sources and must
reproduce them byte for byte. A package from this tool is only as trusted
as that comparison until one has been installed on a band.
"""
import argparse, os, re, struct, sys, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import face_id                                    # noqa: E402  (layout parser / validator)

W, H = 336, 480
DEVICE_TYPE = '567'


class PackError(Exception):
    pass


def read_png_bgra(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise PackError('%s: not a PNG' % path)
    pos, ihdr, idat = 8, None, b''
    while pos < len(data):
        n, typ = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if zlib.crc32(typ + body) & 0xffffffff != struct.unpack('>I', data[pos + 8 + n:pos + 12 + n])[0]:
            raise PackError('%s: bad CRC in %s' % (path, typ))
        if typ == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', body)
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
        pos += 12 + n
    w, h, depth, ctype, _, _, interlace = ihdr
    if (w, h) != (W, H) or depth != 8 or ctype not in (2, 6) or interlace:
        raise PackError('%s: need %dx%d 8-bit RGB/RGBA non-interlaced, got %dx%d depth %d type %d interlace %d'
                        % (path, W, H, w, h, depth, ctype, interlace))
    bpp = 4 if ctype == 6 else 3
    raw, stride = zlib.decompress(idat), w * bpp
    out, prev = bytearray(), bytearray(stride)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
            elif f != 0:
                raise PackError('%s: bad filter %d' % (path, f))
        for x in range(w):
            px = line[x * bpp:(x + 1) * bpp]
            out += bytes((px[2], px[1], px[0], px[3] if bpp == 4 else 255))   # BGRA, straight alpha
        prev = line
    return bytes(out)


def read_project(d):
    fprj = open(os.path.join(d, 'module.fprj'), 'rb').read().decode('utf-8-sig', 'strict')
    if not re.search(r'<FaceProject\s+DeviceType="%s"\s*>' % DEVICE_TYPE, fprj):
        raise PackError('module.fprj: DeviceType must be %s' % DEVICE_TYPE)
    scr = re.findall(r'<Screen\s+Title="([^"]*)"\s+Bitmap="([^"]*)"\s*>', fprj)
    widgets = re.findall(r'<Widget\s[^>]*/>', fprj)
    want = '<Widget Shape="34" Name="app_lua%2Fmain.lua" X="0" Y="0" Width="336" Height="480" Alpha="0" Visible_Src="0" />'
    if len(scr) != 1 or len(widgets) != 1 or widgets[0] != want:
        raise PackError('module.fprj: need one Screen and exactly this widget: %s' % want)
    title, bitmap = scr[0]
    if not title or len(title.encode('utf-8')) >= face_id.TITLE_LEN:
        raise PackError('title empty or too long')
    lua = os.path.join(d, 'app', 'lua')
    names = sorted(os.listdir(lua))
    files = []
    for n in names:
        p = os.path.join(lua, n)
        if not os.path.isfile(p) or not re.fullmatch(r'[A-Za-z0-9_.\-]+', n):
            raise PackError('app/lua/%s: only plain files with simple ASCII names' % n)
        files.append(('lua/' + n, open(p, 'rb').read()))
    if 'lua/main.lua' not in [f[0] for f in files]:
        raise PackError('app/lua/main.lua missing')
    return title, read_png_bgra(os.path.join(d, 'images', bitmap)), files


def build(face_id_str, title, preview, files):
    if not (face_id_str.isdigit() and len(face_id_str) == 9):
        raise PackError('ID must be 9 decimal digits')
    n = len(files)
    if not 1 <= n <= 64:
        raise PackError('1..64 files')
    table = face_id.TABLE_OFF
    first = table + 16 * (n + 1)
    body, recs, off = b'', b'', first
    for i, (name, content) in enumerate(files):
        nm = name.encode('ascii')
        if len(nm) > 255 or len(content) >= 1 << 24:
            raise PackError('%s: name or content too long' % name)
        entry = struct.pack('<I', len(content) | (len(nm) << 24)) + b'\0' * 16 + nm + content
        recs += struct.pack('<IIII', 0x05000000 | i, 0, off, len(entry))
        pad = (-len(entry)) % 4
        body += entry + b'\0' * pad
        off += len(entry) + pad
    main_idx = [f[0] for f in files].index('lua/main.lua')
    recs += struct.pack('<IIII', 0x05000000 | main_idx, 0, 0, 0)      # terminator names the script
    end, rec_end = off, first
    hdr = bytearray(first)
    struct.pack_into('<I', hdr, 0x00, face_id.MAGIC)
    struct.pack_into('<I', hdr, 0x10, 0x800)
    struct.pack_into('<I', hdr, 0x1C, 1)
    struct.pack_into('<I', hdr, face_id.END_OFF, end)
    hdr[face_id.ID_OFF:face_id.ID_OFF + 9] = face_id_str.encode()
    t = title.encode('utf-8')
    hdr[face_id.TITLE_OFF:face_id.TITLE_OFF + len(t)] = t
    struct.pack_into('<I', hdr, face_id.END_OFF2, end)
    # section directory observed in both samples: (count, offset) pairs
    struct.pack_into('<24I', hdr, 0xB0,
                     1, 0x100, 0, 0x110, 0, 0x110, 0, 0x110, 0, 0x110, n, 0x110,
                     0, rec_end - 16, 0, rec_end - 16, 0, rec_end - 16, 0, rec_end - 16, 0, 0, rec_end - 16, 0x10)
    hdr[table:table + len(recs)] = recs
    if len(preview) != W * H * 4:
        raise PackError('preview size')
    out = bytes(hdr) + body + struct.pack('<IHHI', 0, W, H, W * H * 4) + preview
    face_id.parse(out)                                   # must pass the independent validator
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('project')
    ap.add_argument('out')
    ap.add_argument('--id', required=True)
    a = ap.parse_args(argv)
    try:
        title, preview, files = read_project(a.project)
        data = build(a.id, title, preview, files)
    except (PackError, face_id.FaceError, OSError) as e:
        print('REFUSED: %s' % e, file=sys.stderr)
        return 2
    if os.path.exists(a.out):
        print('REFUSED: %s exists' % a.out, file=sys.stderr)
        return 2
    open(a.out, 'wb').write(data)
    import hashlib
    print('OK  %s  id=%s title=%s files=%s  %d bytes sha256 %s' % (a.out, a.id, title, ','.join(f[0] for f in files),
                                                                len(data), hashlib.sha256(data).hexdigest()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
