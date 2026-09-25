#!/usr/bin/env python3
# iso-squash-info.py —— 从一个 ISO 的头部（前几 MB）里解析出 casper 目录下
# filesystem.squashfs 与 filesystem.size 的字节偏移与长度，输出为可直接 eval 的赋值。
#
# 用法: iso-squash-info.py <iso-head.bin>
# 输出:
#   squashfs_off=<字节偏移>
#   squashfs_len=<字节长度>
#   size_off=<字节偏移>
#   size_len=<字节长度>
import sys, struct

data = open(sys.argv[1], "rb").read()
SEC = 2048

def u32le(b, off):
    return struct.unpack_from("<I", b, off)[0]

def read_dir(lba, length):
    off = lba * SEC
    end = off + length
    out = []
    while off < len(data) and off < end:
        rlen = data[off]
        if rlen == 0:
            off = ((off // SEC) + 1) * SEC
            continue
        rec = data[off:off + rlen]
        name = rec[33:33 + rec[32]]
        out.append((name.decode("utf-8", "replace"), u32le(rec, 2), u32le(rec, 10), bool(rec[25] & 2)))
        off += rlen
    return out

def root_dir(off):
    r = data[off + 156:off + 156 + 34]
    return u32le(r, 2), u32le(r, 10)

found = {}
for sec in range(16, 48):
    o = sec * SEC
    if o + 7 > len(data):
        break
    if data[o + 1:o + 6] == b"CD001" and data[o] in (1, 2):
        lba, ln = root_dir(o)
        for name, ext, dlen, isdir in read_dir(lba, ln):
            if isdir and name.lower() == "casper":
                for n2, e2, l2, d2 in read_dir(ext, dlen):
                    low = n2.lower()
                    if "filesystem.squashfs" in low and "squashfs" not in found:
                        found["squashfs"] = (e2 * SEC, l2)
                    if low.startswith("filesystem.size") and "size" not in found:
                        found["size"] = (e2 * SEC, l2)

if "squashfs" not in found:
    sys.stderr.write("iso-squash-info: 找不到 casper/filesystem.squashfs\n")
    sys.exit(1)
print("squashfs_off=%d" % found["squashfs"][0])
print("squashfs_len=%d" % found["squashfs"][1])
if "size" in found:
    print("size_off=%d" % found["size"][0])
    print("size_len=%d" % found["size"][1])
else:
    print("size_off=0")
    print("size_len=0")
