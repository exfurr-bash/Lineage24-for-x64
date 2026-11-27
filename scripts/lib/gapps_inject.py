#!/usr/bin/env python3
"""Injeta o conjunto mínimo de GApps do gbOS86 numa árvore de system.img.

O system.img do Lineage usado pelo Generic_X86_64 é uma imagem "system-as-root"
(o layout é detectado automaticamente):

  layout root      TREE/system/apex, TREE/product, TREE/system_ext
  layout nested    TREE/system/apex, TREE/system/product, TREE/system/system_ext
  layout system    TREE/apex,       TREE/product,        TREE/system_ext

Uso:
  gapps_inject.py --stock-tree DIR --product-tree DIR --system-ext-tree DIR \
                  --manifest FILE [--dry-run] [--layout auto|root|nested|system]

Só o conjunto mínimo documentado em docs/KSU-prep.md é copiado. Labels
SELinux vêm do file_contexts do próprio Lineage (matchpathcon); se ele não
existir, herda o label do diretório pai. Arquivos de APEX ficam SEM xattr,
como no stock.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

# (origem relativa, destino relativo ao "conteúdo" do system)
PRODUCT_DIRS = [
    "priv-app/PrebuiltGmsCore",
    "priv-app/Phonesky",
]
PRODUCT_FILES = [
    "etc/permissions/privapp-permissions-google-p.xml",
    "etc/permissions/split-permissions-google.xml",
    "etc/sysconfig/google.xml",
    "etc/sysconfig/google-hiddenapi-package-whitelist.xml",
    "etc/sysconfig/preinstalled_packages_gms.xml",
    "etc/sysconfig/allowed_apex_com.google.android.gmssystem.xml",
]
PRODUCT_APEX = "apex/com.google.android.gmssystem.prodvic.apex"
SYSTEM_EXT_DIRS = [
    "priv-app/GoogleServicesFramework",
]
SYSTEM_EXT_FILES = [
    "etc/permissions/privapp-permissions-google-se.xml",
]
REQUIRED = [
    ("product", "priv-app/Phonesky"),
    ("product", "priv-app/PrebuiltGmsCore"),
    ("system_ext", "priv-app/GoogleServicesFramework"),
]
APEX_SUFFIX = "com.google.android.gmssystem.prodvic.apex"


def log(msg):
    print(f">> {msg}")


def warn(msg):
    print(f"AVISO: {msg}", file=sys.stderr)


def die(msg):
    print(f"ERRO: {msg}", file=sys.stderr)
    raise SystemExit(1)


def detect_layout(tree):
    if os.path.isdir(os.path.join(tree, "system/apex")):
        if os.path.isdir(os.path.join(tree, "system/product")):
            return "nested"
        return "root"
    if os.path.isdir(os.path.join(tree, "apex")):
        return "system"
    die("não reconheci o layout do system.img (sem system/apex nem apex/)")


def roots(tree, layout):
    if layout == "nested":
        return {
            "system": os.path.join(tree, "system"),
            "product": os.path.join(tree, "system/product"),
            "system_ext": os.path.join(tree, "system/system_ext"),
            "apex": os.path.join(tree, "system/apex"),
        }
    if layout == "root":
        return {
            "system": os.path.join(tree, "system"),
            "product": os.path.join(tree, "product"),
            "system_ext": os.path.join(tree, "system_ext"),
            "apex": os.path.join(tree, "system/apex"),
        }
    return {
        "system": tree,
        "product": os.path.join(tree, "product"),
        "system_ext": os.path.join(tree, "system_ext"),
        "apex": os.path.join(tree, "apex"),
    }


def contexts_file(tree, layout):
    r = roots(tree, layout)
    cand = [
        os.path.join(r["system"], "etc/selinux/plat_file_contexts"),
        os.path.join(r["system_ext"], "etc/selinux/system_ext_file_contexts"),
        os.path.join(r["product"], "etc/selinux/product_file_contexts"),
    ]
    cand = [c for c in cand if os.path.isfile(c)]
    if not cand:
        return None
    out = os.path.join(tree, ".gapps_file_contexts")
    with open(out, "w") as f:
        for c in cand:
            with open(c, "r", errors="replace") as src:
                f.write(src.read())
    return out


def matchpathcon(ctx_file, syn_path):
    if not ctx_file or not shutil.which("matchpathcon"):
        return None
    try:
        p = subprocess.run(
            ["matchpathcon", "-n", "-f", ctx_file, syn_path],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    out = p.stdout.strip().splitlines()
    if not out:
        return None
    ctx = out[-1].split()[-1]
    if not ctx.startswith("u:object_r:") or ctx == "<<none>>":
        return None
    return ctx


def get_selinux(path):
    try:
        v = os.getxattr(path, b"security.selinux")
    except OSError:
        return None
    return v.split(b"\x00", 1)[0].decode(errors="replace")


def set_selinux(path, ctx):
    if not ctx or os.geteuid() != 0:
        return False
    try:
        os.setxattr(path, b"security.selinux", ctx.encode() + b"\x00")
        return True
    except OSError as e:
        warn(f"não apliquei {ctx} em {path}: {e}")
        return False


def clear_selinux(path):
    try:
        os.removexattr(path, b"security.selinux")
    except OSError:
        pass


def parent_label(root, rel, fallback):
    cur = os.path.dirname(os.path.join(root, rel))
    while cur and cur.startswith(root):
        v = get_selinux(cur)
        if v:
            return v
        if cur == root:
            break
        cur = os.path.dirname(cur)
    return fallback


def fix_owner(path):
    if os.geteuid() != 0:
        return
    try:
        st = os.lstat(path)
        if os.path.islink(path):
            os.lchown(path, 0, 0)
        else:
            os.chown(path, 0, 0)
            os.chmod(path, st.st_mode & 0o7777)
    except OSError as e:
        warn(f"não ajustei dono/modo de {path}: {e}")


def copy_file(src, dst, ctx):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        os.chmod(dst, 0o644)
    shutil.copy2(src, dst, follow_symlinks=True)
    fix_owner(dst)
    if ctx:
        set_selinux(dst, ctx)
    return dst


def copy_tree(src, dst, ctx):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True, copy_function=shutil.copy2)
    for dp, dns, fns in os.walk(dst):
        fix_owner(dp)
        for n in dns + fns:
            fix_owner(os.path.join(dp, n))
    if ctx:
        # Aplica no diretório e em arquivos; não sobrescreve labels que já
        # vieram corretos do matchpathcon (aplicado depois, por path).
        for dp, _dns, fns in os.walk(dst):
            set_selinux(dp, ctx)
            for n in fns:
                p = os.path.join(dp, n)
                if not os.path.islink(p):
                    set_selinux(p, ctx)
    return dst


def valid_label_path(part, rel):
    if part == "product":
        return "/product/" + rel
    if part == "system_ext":
        return "/system_ext/" + rel
    return "/system/apex/" + os.path.basename(rel)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock-tree", required=True)
    ap.add_argument("--product-tree", required=True)
    ap.add_argument("--system-ext-tree", required=True)
    ap.add_argument("--manifest")
    ap.add_argument("--layout", choices=["auto", "root", "nested", "system"], default="auto")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    for d in (args.stock_tree, args.product_tree, args.system_ext_tree):
        if not os.path.isdir(d):
            die(f"diretório ausente: {d}")

    layout = detect_layout(args.stock_tree) if args.layout == "auto" else args.layout
    r = roots(args.stock_tree, layout)
    log(f"layout detectado: {layout} (product={r['product']}, apex={r['apex']})")

    p_src = os.path.join(args.product_tree, "product")
    if not os.path.isdir(p_src):
        p_src = args.product_tree
    se_src = os.path.join(args.system_ext_tree, "system_ext")
    if not os.path.isdir(se_src):
        se_src = args.system_ext_tree
    if not os.path.isdir(p_src) or not os.path.isdir(se_src):
        die("as árvores product_a/system_ext_a não têm o layout esperado")

    ctx_file = contexts_file(args.stock_tree, layout)
    if not ctx_file:
        warn("file_contexts não encontrado; labels virão do diretório pai")

    copied = []

    def dest(part, rel):
        return os.path.join(r[part], rel)

    def ctx_for(part, rel):
        return matchpathcon(ctx_file, valid_label_path(part, rel))

    def do_dir(part, rel):
        src = os.path.join(p_src if part == "product" else se_src, rel)
        if not os.path.isdir(src):
            warn(f"origem ausente (opcional): {part}/{rel}")
            return
        dst = dest(part, rel)
        if args.dry_run:
            log(f"[dry-run] copiaria diretório {src} -> {dst}")
            return
        ctx = ctx_for(part, rel) or parent_label(args.stock_tree, os.path.relpath(dst, args.stock_tree), "u:object_r:system_file:s0")
        copy_tree(src, dst, ctx)
        copied.append(os.path.relpath(dst, args.stock_tree))
        log(f"{part}/{rel} <- {src}")

    def do_file(part, rel, required=False):
        src = os.path.join(p_src if part == "product" else se_src, rel)
        if not os.path.isfile(src):
            (die if required else warn)(f"origem ausente: {part}/{rel}")
            return
        dst = dest(part, rel)
        if args.dry_run:
            log(f"[dry-run] copiaria {src} -> {dst}")
            return
        ctx = ctx_for(part, rel) or parent_label(args.stock_tree, os.path.relpath(dst, args.stock_tree), "u:object_r:system_file:s0")
        copy_file(src, dst, ctx)
        copied.append(os.path.relpath(dst, args.stock_tree))
        log(f"{part}/{rel} <- {src}")

    for rel in PRODUCT_DIRS:
        do_dir("product", rel)
    for rel in PRODUCT_FILES:
        do_file("product", rel)
    for rel in SYSTEM_EXT_DIRS:
        do_dir("system_ext", rel)
    for rel in SYSTEM_EXT_FILES:
        do_file("system_ext", rel, required=True)

    # O APEX precisa ficar no diretório que o apexd realmente varre.
    apex_src = os.path.join(p_src, PRODUCT_APEX)
    if not os.path.isfile(apex_src):
        die(f"APEX do GMS ausente na origem: {apex_src}")
    apex_dst = os.path.join(r["apex"], APEX_SUFFIX)
    if not args.dry_run:
        os.makedirs(r["apex"], exist_ok=True)
        copy_file(apex_src, apex_dst, None)
        clear_selinux(apex_dst)  # stock do Lineage não tem xattr em /system/apex
        copied.append(os.path.relpath(apex_dst, args.stock_tree))
        log(f"apex <- {apex_src} (sem xattr, como no stock)")

    if args.dry_run:
        log("dry-run: nada escrito")
        return 0

    for part, rel in REQUIRED:
        p = dest(part, rel)
        if not os.path.exists(p):
            die(f"injeção incompleta: {p}")
    if not os.path.isfile(apex_dst):
        die(f"injeção incompleta: {apex_dst}")

    # Nenhum xattr de APEX deve ter sobrado.
    apex_bad = []
    if get_selinux(apex_dst) is not None:
        apex_bad.append(apex_dst)
    for n in os.listdir(r["apex"]):
        p = os.path.join(r["apex"], n)
        if n.endswith(".apex") and get_selinux(p) is not None:
            apex_bad.append(p)
    if apex_bad:
        warn(f"{len(apex_bad)} APEX(es) com security.selinux (stock não tem): {apex_bad[:3]}")

    if ctx_file:
        try:
            os.unlink(ctx_file)
        except OSError:
            pass

    summary = {
        "layout": layout,
        "stock_tree": args.stock_tree,
        "product_tree": args.product_tree,
        "system_ext_tree": args.system_ext_tree,
        "apex": apex_dst,
        "injected": sorted(copied),
        "injected_count": len(copied),
        "apex_with_selinux": apex_bad,
    }
    if args.manifest:
        with open(args.manifest, "w") as f:
            json.dump(summary, f, indent=2, sort_keys=True)
    print(json.dumps(summary, indent=2, sort_keys=True))
    log("injeção concluída")
    return 0


if __name__ == "__main__":
    sys.exit(main())
