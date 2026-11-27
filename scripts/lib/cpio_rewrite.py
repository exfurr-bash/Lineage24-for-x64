#!/usr/bin/env python3
"""Reescreve um arquivo CPIO newc (Android ramdisk) trocando módulos .ko.

Uso:
  cpio_rewrite.py --cpio rd.cpio --modules-dir modstaging --out rd.new.cpio
                  [--builtin ext4.ko,jbd2.ko,...] [--report FILE]

Regras:
- entradas lib/modules/**/*.ko cujo basename existe em --modules-dir são
  substituídas pelo arquivo novo;
- entradas cujo basename está em --builtin são removidas (viraram builtin no
  kernel novo);
- entradas sem substituto são mantidas e reportadas;
- múltiplos trailers/pedaços de cpio concatenados são preservados;
- headers originais são copiados byte-a-byte, alterando só o campo size.
"""
import argparse
import json
import os
import sys

ALIGN = 4
HDR = 110
MAGIC = b"070701"


def pad4(b: bytes) -> bytes:
    n = (-len(b)) % ALIGN
    return b + (b"\x00" * n if n else b"")


def field(h: bytes, i: int) -> int:
    return int(h[6 + 8 * i:6 + 8 * (i + 1)], 16)


def set_field(h: bytearray, i: int, value: int) -> None:
    h[6 + 8 * i:6 + 8 * (i + 1)] = b"%08x" % (value & 0xFFFFFFFF)


def parse(data: bytes, verbose: bool = False):
    recs = []
    i = 0
    n = len(data)
    while True:
        i = data.find(MAGIC, i)
        if i < 0 or i + HDR > n:
            break
        h = data[i:i + HDR]
        try:
            size = field(h, 6)
            namesize = field(h, 11)
        except ValueError:
            i += 1
            continue
        if namesize < 1 or namesize > 4096:
            i += 1
            continue
        nameoff = i + HDR
        nameb = data[nameoff:nameoff + namesize]
        if len(nameb) < namesize or not nameb.endswith(b"\x00"):
            i += 1
            continue
        name = nameb[:-1]
        is_trailer = name == b"TRAILER!!!"
        start = (nameoff + namesize + 3) // 4 * 4
        end = start + size
        if not is_trailer and end > n:
            i += 1
            continue
        recs.append({
            "h": i, "size": size, "name": name, "dat": start,
            "trailer": is_trailer,
        })
        # trailer tem size 0; continua procurando o próximo stream
        i = (nameoff + namesize) if is_trailer else start + ((size + 3) // 4) * 4
    if not recs:
        raise SystemExit("cpio: nenhum header newc encontrado")
    if verbose:
        print(f"cpio: {len(recs)} entradas, {sum(1 for r in recs if r['trailer'])} trailer(s)")
    return recs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cpio", required=True)
    ap.add_argument("--modules-dir", required=True,
                    help="diretório com os .ko novos (busca recursiva por basename)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--builtin", default="ext4.ko,jbd2.ko,mbcache.ko,crc16.ko")
    ap.add_argument("--report", help="arquivo JSON com o resumo")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    builtin = {x.strip() for x in args.builtin.split(",") if x.strip()}
    modmap = {}
    for dp, _dn, fn in os.walk(args.modules_dir):
        for sf in fn:
            if sf.endswith(".ko"):
                modmap[sf] = os.path.join(dp, sf)

    data = open(args.cpio, "rb").read()
    recs = parse(data, verbose=True)
    kos = [r for r in recs if r["name"].startswith(b"lib/modules/") and r["name"].endswith(b".ko")]
    print(f"cpio: {len(kos)} .ko no ramdisk; {len(modmap)} .ko no build")

    replaced = 0
    removed = []
    missing = []
    for r in recs:
        r["newdata"] = None
        r["skip"] = False
        nm = r["name"]
        if r["trailer"] or not (nm.startswith(b"lib/modules/") and nm.endswith(b".ko")):
            continue
        base = nm.rsplit(b"/", 1)[1].decode()
        full = modmap.get(base)
        if full is None:
            if base in builtin:
                r["skip"] = True
                removed.append(base)
            else:
                missing.append(base)
            continue
        r["newdata"] = open(full, "rb").read()
        r["size"] = len(r["newdata"])
        replaced += 1

    print(f"cpio: substituídos={replaced} builtin removidos={len(removed)} sem substituto={len(missing)}")
    if removed:
        print("cpio: builtin removidos:", ", ".join(sorted(removed)[:12]))
    if missing:
        print("cpio: ATENÇÃO sem substituto:", ", ".join(sorted(missing)[:12]),
              "..." if len(missing) > 12 else "")

    if args.dry_run:
        print("cpio: dry-run, nada escrito")
        return 0

    out = bytearray()
    pos = 0
    for idx, r in enumerate(recs):
        nxt = recs[idx + 1]["h"] if idx + 1 < len(recs) else len(data)
        if r["skip"]:
            pos = nxt
            continue
        if r["h"] > pos:
            out += data[pos:r["h"]]
        body = r["newdata"] if r["newdata"] is not None else data[r["dat"]:r["dat"] + r["size"]]
        h = bytearray(data[r["h"]:r["h"] + HDR])
        set_field(h, 6, len(body))
        name = r["name"] + b"\x00"
        out += pad4(bytes(h) + name)
        out += pad4(body)
        pos = nxt
    out += data[pos:]

    if bytes(out[:6]) != MAGIC:
        raise SystemExit("cpio: saída inválida (sem magic newc)")
    # valida a saída relendo
    out_recs = parse(bytes(out), verbose=False)
    out_trailers = sum(1 for r in out_recs if r["trailer"])
    print(f"cpio: saída {len(out)} bytes ({len(data)} antes), {len(out_recs)} entradas, {out_trailers} trailer(s)")
    with open(args.out, "wb") as f:
        f.write(out)

    summary = {
        "input": args.cpio, "output": args.out,
        "input_bytes": len(data), "output_bytes": len(out),
        "entries": len(recs), "output_entries": len(out_recs),
        "replaced": replaced,
        "builtin_removed": sorted(removed),
        "missing": sorted(missing),
    }
    if args.report:
        with open(args.report, "w") as f:
            json.dump(summary, f, indent=2, sort_keys=True)
    if missing:
        print("cpio: aviso: módulos sem substituto foram mantidos do original")
    return 0


if __name__ == "__main__":
    sys.exit(main())
