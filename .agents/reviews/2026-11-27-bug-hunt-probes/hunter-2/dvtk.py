# deletion vectors by hand: roaring (portable), DV files, Z85
import struct, zlib, uuid
Z = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#"
def z85(b):
    assert len(b) % 4 == 0
    out = ""
    for i in range(0, len(b), 4):
        v = struct.unpack(">I", b[i:i+4])[0]; s = ""
        for _ in range(5): s = Z[v % 85] + s; v //= 85
        out += s
    return out
def r32(vals, runs=False, force_bitmap=False):
    """portable 32-bit roaring of sorted unique ints < 2^32"""
    cont = {}
    for v in vals: cont.setdefault(v >> 16, []).append(v & 0xFFFF)
    keys = sorted(cont); n = len(keys)
    bodies = []
    for k in keys:
        lo = cont[k]
        if runs:
            rs = []; s = p = lo[0]
            for x in lo[1:]:
                if x == p + 1: p = x
                else: rs.append((s, p - s)); s = p = x
            rs.append((s, p - s))
            bodies.append(struct.pack("<H", len(rs)) + b"".join(struct.pack("<HH", a, l) for a, l in rs))
        elif len(lo) > 4096 or force_bitmap:
            bm = bytearray(8192)
            for x in lo: bm[x >> 3] |= 1 << (x & 7)
            bodies.append(bytes(bm))
        else:
            bodies.append(b"".join(struct.pack("<H", x) for x in lo))
    if runs:
        out = struct.pack("<I", 12347 | ((n - 1) << 16)) + bytes([0xFF] * ((n + 7) // 8))
    else:
        out = struct.pack("<II", 12346, n)
    out += b"".join(struct.pack("<HH", k, len(cont[k]) - 1) for k in keys)
    if not runs or n >= 4:
        off = len(out) + 4 * n
        for b in bodies: out += struct.pack("<I", off); off += len(b)
    return out + b"".join(bodies)
def r64(vals, **kw):
    hi = {}
    for v in sorted(vals): hi.setdefault(v >> 32, []).append(v & 0xFFFFFFFF)
    out = struct.pack("<Q", len(hi))
    for k in sorted(hi): out += struct.pack("<I", k) + r32(hi[k], **kw)
    return out
MAGIC = struct.pack("<I", 1681511377)
def dvdata(vals, **kw): return MAGIC + r64(vals, **kw)
def inline(vals, pad=b"", **kw):
    d = dvdata(vals, **kw); size = len(d)
    d += pad
    while len(d) % 4: d += b"\0"
    return {"storageType": "i", "pathOrInlineDv": z85(d), "sizeInBytes": size, "cardinality": len(set(vals))}
def dvfile(path, datas, version=1):
    """write a DV file holding several vectors; returns [(offset, size)]"""
    out = bytes([version]); pos = []
    for d in datas:
        pos.append((len(out), len(d)))
        out += struct.pack(">I", len(d)) + d + struct.pack(">I", zlib.crc32(d) & 0xFFFFFFFF)
    open(path, "wb").write(out)
    return pos
def udesc(u, offset, size, card, prefix=""):
    return {"storageType": "u", "pathOrInlineDv": prefix + z85(u.bytes), "offset": offset, "sizeInBytes": size, "cardinality": card}
def uname(u, prefix=""): return (prefix + "/" if prefix else "") + "deletion_vector_%s.bin" % u
