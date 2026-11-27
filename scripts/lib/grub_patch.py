#!/usr/bin/env python3
"""Reescrita/validação de grub.cfg (ISO live e entrada instalada do KSU).

Subcomandos:
  iso-titles  --cfg FILE --variant ksu|gapps
  entry       --cfg FILE [--title "LineageOS 24.0 (dbg, persistent data)"]
  check-entry --cfg FILE

Todos são idempotentes. O chamador faz backup e escrita atômica.
"""
import argparse
import re
import sys

SUFFIX = {
    "ksu": "KernelSU + Vulkan",
    "gapps": "KernelSU + Vulkan + GApps",
}
ENTRY_RE = re.compile(r"^menuentry\s+['\"]([^'\"]+)['\"]\s*\{", re.M)
TITLE_RE = re.compile(r'^((?:menu)?entry\s+")([^"]+)("(?:\s*\{)?)$', re.M)
SUBMENU_RE = re.compile(r'^(submenu\s+")([^"]+)("(?:\s*\{)?)$', re.M)


def die(msg):
    print(f"ERRO: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read_text(path: str) -> str:
    with open(path, "r") as f:
        return f.read()


def write_text(path: str, text: str) -> None:
    with open(path, "w") as f:
        f.write(text)


def add_suffix(title: str, suffix: str) -> str:
    if "KernelSU" in title:
        if suffix == SUFFIX["gapps"] and "+ GApps" not in title:
            return re.sub(r"\(([^)]*KernelSU \+ Vulkan)\)", r"(\1 + GApps)", title)
        return title
    m = re.match(r"^(.*?)(\s*\(([^)]*)\))$", title)
    if m:
        return f"{m.group(1)} ({m.group(3)}, {suffix})"
    return f"{title} ({suffix})"


def iso_titles(cfg: str, variant: str) -> int:
    suffix = SUFFIX[variant]
    s = read_text(cfg)
    changed = 0

    def repl(m):
        nonlocal changed
        title = m.group(2)
        # A entrada usada como âncora para o diagnóstico não é renomeada;
        # caso contrário o replace do bloco abaixo deixa de casar.
        if title.startswith("Force using Mesa llvmpipe graphics"):
            return m.group(0)
        new = add_suffix(title, suffix)
        if new != title:
            changed += 1
            return m.group(1) + new + m.group(3)
        return m.group(0)

    s2 = TITLE_RE.sub(repl, s)
    s2 = SUBMENU_RE.sub(repl, s2)
    if changed == 0 and "KernelSU" not in s2:
        die("nenhum título 'LineageOS 24.0 Live' encontrado no grub.cfg")

    anchor = ('    menuentry "Force using Mesa llvmpipe graphics" {\n'
              '        boot_android_with_default_mount_options androidboot.graphics=llvmpipe\n'
              '    }\n')
    diag_title = f"Select Vulkan APEX: swiftshader (software Vulkan for diagnostics, {suffix})"
    if diag_title not in s2:
        if anchor not in s2:
            die("entrada 'Force using Mesa llvmpipe graphics' não encontrada (layout da ISO mudou?)")
        diag = ('    menuentry "' + diag_title + '" {\n'
                '        boot_android_with_default_mount_options androidboot.vulkan_apex=2\n'
                '    }\n')
        s2 = s2.replace(anchor, anchor + diag)
        changed += 1

    write_text(cfg, s2)
    print(f"grub.cfg: {changed} alteração(ões), variante {variant}")
    return 0


def find_block(s: str, title: str):
    m = ENTRY_RE.search(s)
    while m:
        if m.group(1) == title:
            start = m.start()
            end_m = re.search(r"^\}", s[m.end():], re.M)
            if not end_m:
                die(f"fim do menuentry '{title}' não encontrado")
            end = m.end() + end_m.end()
            return start, end, s[start:end]
        m = ENTRY_RE.search(s, m.end())
    return None


def transform_entry(block: str) -> str:
    b = block.replace("LineageOS 24.0 (dbg, persistent data)",
                      "LineageOS 24.0 (KSU, persistent data)")
    # kernel -> kernel.ksu (não toca kernel.ksu já transformado)
    b, n_kernel = re.subn(r"(?<![.\w-])kernel(?!\.ksu)(?=\s|$)", "kernel.ksu", b)
    # ramdisk .img -> .ksu.img
    b, n_ramdisk = re.subn(r"ramdisk-all-combined\.img(?!\.ksu)", "ramdisk-all-combined.ksu.img", b)
    # android_dir com boundary (espaço, aspas ou fim)
    b, n_dir = re.subn(r"androidboot\.android_dir=android-Generic_x86_64(?=$|[\s\"'])",
                       "androidboot.android_dir=android-Generic_x86_64-ksu", b, flags=re.M)
    problems = []
    if "kernel.ksu" not in b:
        problems.append("kernel.ksu")
    if "ramdisk-all-combined.ksu.img" not in b:
        problems.append("ramdisk-all-combined.ksu.img")
    if "android_dir=android-Generic_x86_64-ksu" not in b:
        problems.append("android_dir=...-ksu")
    if problems:
        die("entrada base não pôde ser transformada (faltou: " + ", ".join(problems) + ")")
    return b


def entry(cfg: str, title: str = "LineageOS 24.0 (dbg, persistent data)") -> int:
    s = read_text(cfg)
    if "kernel.ksu" in s and "android_dir=android-Generic_x86_64-ksu" in s:
        print("grub.cfg: entrada KSU já existe")
        return 0
    found = find_block(s, title)
    if not found:
        die(f"entrada base não encontrada: {title!r}")
    start, end, block = found
    newblock = transform_entry(block)
    s2 = s[:end] + "\n" + newblock + s[end:]
    write_text(cfg, s2)
    print("grub.cfg: entrada KSU inserida")
    return 0


def check_entry(cfg: str) -> int:
    s = read_text(cfg)
    found = find_block(s, "LineageOS 24.0 (KSU, persistent data)")
    if not found:
        die("entrada 'LineageOS 24.0 (KSU, persistent data)' ausente")
    block = found[2]
    need = ["kernel.ksu", "ramdisk-all-combined.ksu.img", "android_dir=android-Generic_x86_64-ksu"]
    miss = [x for x in need if x not in block]
    if miss:
        die("entrada KSU incompleta: " + ", ".join(miss))
    print("grub.cfg: entrada KSU OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p1 = sub.add_parser("iso-titles")
    p1.add_argument("--cfg", required=True)
    p1.add_argument("--variant", choices=sorted(SUFFIX), required=True)
    p2 = sub.add_parser("entry")
    p2.add_argument("--cfg", required=True)
    p2.add_argument("--title", default="LineageOS 24.0 (dbg, persistent data)")
    p3 = sub.add_parser("check-entry")
    p3.add_argument("--cfg", required=True)
    args = ap.parse_args()
    if args.cmd == "iso-titles":
        return iso_titles(args.cfg, args.variant)
    if args.cmd == "entry":
        return entry(args.cfg, args.title)
    return check_entry(args.cfg)


if __name__ == "__main__":
    sys.exit(main())
