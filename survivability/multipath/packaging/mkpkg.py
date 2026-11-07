#!/usr/bin/env python3
"""
mkpkg — write a .deb or OpenWrt .ipk from a staged root, with no dpkg/opkg
tooling needed (builds on macOS). Output is reproducible: every entry is
owned root:root and stamped with SOURCE_DATE_EPOCH.

  mkpkg.py deb|ipk ROOT CONTROLDIR OUT

ROOT        staged filesystem (becomes data.tar.gz)
CONTROLDIR  `control` plus optional conffiles/postinst/prerm/postrm/preinst
            (becomes control.tar.gz; Installed-Size is filled in here)
"""

import gzip
import io
import os
import sys
import tarfile

EPOCH = int(os.environ.get("SOURCE_DATE_EPOCH", "1761436800"))
SCRIPTS = {"preinst", "postinst", "prerm", "postrm"}


def _tar(entries):
    """entries: list of (arcname, path_or_None_for_dir, mode) -> gzip bytes."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for arc, path, mode in entries:
            ti = tarfile.TarInfo(arc)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = EPOCH
            ti.mode = mode
            if path is None:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            elif os.path.islink(path):
                ti.type = tarfile.SYMTYPE
                ti.linkname = os.readlink(path)
                tf.addfile(ti)
            else:
                with open(path, "rb") as f:
                    data = f.read()
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=EPOCH, compresslevel=9) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()


def _walk(root):
    entries, size = [("./", None, 0o755)], 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        if rel != ".":
            entries.append(("./" + rel + "/", None, 0o755))
        for fn in sorted(filenames):
            p = os.path.join(dirpath, fn)
            arc = "./" + os.path.normpath(os.path.join(rel, fn))
            mode = 0o755 if os.access(p, os.X_OK) else 0o644
            entries.append((arc, p, mode))
            if not os.path.islink(p):
                size += os.path.getsize(p)
    return entries, size


def _ar(members):
    out = bytearray(b"!<arch>\n")
    for name, data in members:
        hdr = (f"{name:<16}{EPOCH:<12}{0:<6}{0:<6}{0o100644:<8o}{len(data):<10}`\n")
        out += hdr.encode("ascii")
        out += data
        if len(data) % 2:
            out += b"\n"
    return bytes(out)


def main():
    if len(sys.argv) != 5 or sys.argv[1] not in ("deb", "ipk"):
        sys.exit(__doc__)
    fmt, root, ctldir, outpath = sys.argv[1:]

    data_entries, size = _walk(root)
    data = _tar(data_entries)

    with open(os.path.join(ctldir, "control")) as f:
        control = f.read().rstrip("\n") + "\n"
    control += f"Installed-Size: {(size + 1023) // 1024}\n"
    tmp_control = os.path.join(ctldir, ".control.gen")
    with open(tmp_control, "w") as f:
        f.write(control)

    ctl_entries = [("./", None, 0o755), ("./control", tmp_control, 0o644)]
    for fn in sorted(os.listdir(ctldir)):
        if fn in ("control", ".control.gen"):
            continue
        ctl_entries.append(("./" + fn, os.path.join(ctldir, fn),
                            0o755 if fn in SCRIPTS else 0o644))
    ctl = _tar(ctl_entries)
    os.remove(tmp_control)

    if fmt == "deb":
        blob = _ar([("debian-binary", b"2.0\n"),
                    ("control.tar.gz", ctl),
                    ("data.tar.gz", data)])
    else:
        # OpenWrt opkg .ipk: a gzipped tar of the same three members
        d = os.path.dirname(os.path.abspath(outpath))
        parts = {"debian-binary": b"2.0\n", "data.tar.gz": data, "control.tar.gz": ctl}
        tmp = []
        for n, b in parts.items():
            p = os.path.join(d, "." + n)
            with open(p, "wb") as f:
                f.write(b)
            tmp.append(("./" + n, p, 0o644))
        blob = _tar(tmp)
        for _, p, _ in tmp:
            os.remove(p)

    with open(outpath, "wb") as f:
        f.write(blob)
    print(f"wrote {outpath} ({len(blob)} bytes)")


if __name__ == "__main__":
    main()
