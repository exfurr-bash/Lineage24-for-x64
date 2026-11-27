#!/usr/bin/env python3
"""Converte a metadata do depmod (layout com subdiretórios) para o layout
FLAT usado no vendor_dlkm do Android (lib/modules/<nome>.ko) e valida que
nenhuma dependência aponta para arquivo inexistente.

Uso:
  flatten_depmod.py --modules-root MODSTAGE/lib/modules/7.2.0+ \
                    --flat-dir  ROOT/lib/modules \
                    --modules-load ROOT/lib/modules/modules.load \
                    --bt-modules "bluetooth btmtk btrtl btintel btbcm btusb" \
                    [--builtin-list config/known-builtins.txt] [--check] [--report FILE]

Saída: modules.dep, modules.softdep e modules.alias planos em --flat-dir.
O modules.load existente é preservado e a cadeia BT é acrescentada.
"""
import argparse
import json
import os
import re
import sys

KO_RE = re.compile(r"(?:^|[\s:])([^\s:]+\.ko)(?=$|[\s:])")


def basename_mod(path: str) -> str:
    return os.path.basename(path)


def module_key(name: str) -> str:
    """Normaliza nome de módulo para a chave usada nos .ko flat.

    modules.dep usa caminhos com .ko; modules.alias/softdep usam nomes sem
    extensão. Os dois formatos precisam casar com o conjunto flat.
    """
    b = basename_mod(name)
    return b if b.endswith(".ko") else b + ".ko"


def read_builtins(root: str, extra: str | None) -> set[str]:
    builtins: set[str] = set()
    f = os.path.join(root, "modules.builtin")
    if os.path.isfile(f):
        for line in open(f, errors="replace"):
            line = line.strip()
            if line.endswith(".ko"):
                builtins.add(basename_mod(line))
    if extra and os.path.isfile(extra):
        for line in open(extra, errors="replace"):
            line = line.strip()
            if line and not line.startswith("#"):
                builtins.add(basename_mod(line))
    return builtins


def flat_modules(flat_dir: str) -> set[str]:
    out = set()
    for name in os.listdir(flat_dir):
        if name.endswith(".ko"):
            out.add(name)
    return out


def flatten_dep(root: str, flat: set[str], builtins: set[str], allow_missing: set[str]):
    src = os.path.join(root, "modules.dep")
    if not os.path.isfile(src):
        raise SystemExit(f"sem {src}")
    lines = []
    missing = []
    builtin_deps = 0
    for raw in open(src, errors="replace"):
        raw = raw.rstrip("\n")
        if not raw.strip():
            continue
        if ": " in raw:
            mod, deps = raw.split(": ", 1)
            deps = deps.split()
        elif raw.endswith(":"):
            mod, deps = raw[:-1], []
        else:
            mod, deps = raw, []
        mb = basename_mod(mod)
        if mb not in flat:
            if mb in builtins or mb in allow_missing:
                continue
            missing.append(mb)
            continue
        keep = []
        for d in deps:
            db = basename_mod(d)
            if db in flat:
                keep.append(db)
            elif db in builtins:
                builtin_deps += 1
            elif db in allow_missing:
                builtin_deps += 1
            else:
                missing.append(db)
        lines.append(f"{mb}: {' '.join(keep)}".rstrip())
    return lines, missing, builtin_deps


def flatten_alias(root: str, flat: set[str], builtins: set[str]):
    src = os.path.join(root, "modules.alias")
    if not os.path.isfile(src):
        return [], 0
    out, dropped = [], 0
    for raw in open(src, errors="replace"):
        raw = raw.rstrip("\n")
        if not raw.strip():
            continue
        parts = raw.split()
        if len(parts) < 3 or parts[0] != "alias":
            continue
        target_raw = parts[-1]
        target = basename_mod(target_raw)
        key = module_key(target_raw)
        if key in flat:
            out.append(" ".join(parts[:-1] + [target]))
        elif key in builtins:
            dropped += 1
    return out, dropped


def flatten_softdep(root: str, flat: set[str], builtins: set[str]):
    src = os.path.join(root, "modules.softdep")
    if not os.path.isfile(src):
        return [], 0
    out, dropped = [], 0
    for raw in open(src, errors="replace"):
        raw = raw.rstrip("\n")
        if not raw.strip():
            continue
        parts = raw.split()
        if len(parts) < 2:
            continue
        kind = parts[0].rstrip(":")
        mods = []
        for m in parts[1:]:
            b = basename_mod(m)
            key = module_key(m)
            if key in flat:
                mods.append(b)
            elif key in builtins:
                dropped += 1
        if mods:
            out.append(f"{kind}: {' '.join(mods)}")
    return out, dropped


def ensure_load(path: str, bt_modules: list[str], flat: set[str], builtins: set[str]):
    lines = []
    if os.path.isfile(path):
        lines = [x.rstrip("\n") for x in open(path, errors="replace") if x.strip()]
    have = set(lines)
    added = []
    for m in bt_modules:
        m = m.strip()
        if not m or m in have:
            continue
        if m + ".ko" not in flat and m + ".ko" not in builtins:
            print(f"AVISO: módulo {m} não existe no vendor_dlkm; não adicionado ao modules.load",
                  file=sys.stderr)
            continue
        lines.append(m)
        have.add(m)
        added.append(m)
    return lines, added


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--modules-root", required=True)
    ap.add_argument("--flat-dir", required=True)
    ap.add_argument("--modules-load")
    ap.add_argument("--bt-modules", default="")
    ap.add_argument("--builtin-list")
    ap.add_argument("--allow-missing", default="",
                    help="nomes de módulos .ko aceitos como opcionais")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--report")
    args = ap.parse_args()

    if not os.path.isdir(args.flat_dir):
        raise SystemExit(f"sem diretório flat: {args.flat_dir}")
    flat = flat_modules(args.flat_dir)
    if not flat:
        raise SystemExit(f"nenhum .ko em {args.flat_dir}")
    builtins = read_builtins(args.modules_root, getattr(args, "builtin_list", None))
    allow = {x.strip() for x in args.allow_missing.split(",") if x.strip()}

    dep, missing, builtin_deps = flatten_dep(args.modules_root, flat, builtins, allow)
    alias, alias_dropped = flatten_alias(args.modules_root, flat, builtins)
    softdep, softdep_dropped = flatten_softdep(args.modules_root, flat, builtins)
    load_lines, load_added = ([], [])
    if args.modules_load:
        load_lines, load_added = ensure_load(args.modules_load, args.bt_modules.split(), flat, builtins)

    listed = {line.split(":", 1)[0] for line in dep}
    unlisted = sorted(flat - listed)

    summary = {
        "flat_modules": len(flat),
        "dep_lines": len(dep),
        "builtin_deps_pruned": builtin_deps,
        "missing": sorted(set(missing)),
        "alias_lines": len(alias),
        "alias_dropped_builtin": alias_dropped,
        "softdep_lines": len(softdep),
        "softdep_dropped_builtin": softdep_dropped,
        "unlisted_modules": unlisted,
        "modules_load_added": load_added,
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    if args.report:
        with open(args.report, "w") as f:
            json.dump(summary, f, indent=2, sort_keys=True)
    if missing:
        raise SystemExit("ERRO: dependências apontam para módulos inexistentes: "
                         + ", ".join(sorted(set(missing))[:20]))
    if args.check:
        print("check OK: 0 dependências ausentes")
        return 0

    os.makedirs(args.flat_dir, exist_ok=True)
    with open(os.path.join(args.flat_dir, "modules.dep"), "w") as f:
        f.write("\n".join(dep) + "\n")
    if alias:
        with open(os.path.join(args.flat_dir, "modules.alias"), "w") as f:
            f.write("\n".join(alias) + "\n")
    if softdep:
        with open(os.path.join(args.flat_dir, "modules.softdep"), "w") as f:
            f.write("\n".join(softdep) + "\n")
    if args.modules_load and load_lines:
        with open(args.modules_load, "w") as f:
            f.write("\n".join(load_lines) + "\n")
    print(f"OK: metadata flat escrita em {args.flat_dir} (0 dependências ausentes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
