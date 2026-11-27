#!/usr/bin/env python3
"""Patches idempotentes aplicados à árvore extraída do vendor.img.

Subcomandos:
  hwc    ROOT
  ucm    ROOT
  vulkan ROOT XMLDIR
  bt     ROOT SOURCE_ROOT
  check  ROOT [--bt] [--vulkan] [--hwc] [--ucm]

SELinux: copia o xattr security.selinux da origem quando existir; para
arquivos novos aplica o contexto explícito conhecido. Requer root para
setxattr de security.* em geral.
"""
import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys

VULKAN_XMLS = [
    "android.hardware.vulkan.compute-0.prebuilt.xml",
    "android.hardware.vulkan.level-1.prebuilt.xml",
    "android.hardware.vulkan.version-1_3.prebuilt.xml",
    "android.software.opengles.deqp.level-latest.prebuilt.xml",
    "android.software.vulkan.deqp.level-latest.prebuilt.xml",
]

BT_BIN = "bin/hw/android.hardware.bluetooth-service.desktop"
BT_CONFIGS = [
    "etc/init/bluetooth-service-desktop.rc",
    "etc/vintf/manifest/bluetooth-service-desktop.xml",
    "etc/permissions/android.hardware.bluetooth.xml",
    "etc/permissions/android.hardware.bluetooth_le.xml",
]
BT_LIBS = [
    "libbthcihal.dylib.so",
    "libandroid_desktop_bluetooth_hcihal.dylib.so",
    "libandroid_hardware_bluetooth_V1.dylib.so",
    "libbinder_ndk_sys.dylib.so",
    "libbinder_rs_ndk_compat.dylib.so",
    "libbytes.dylib.so",
    "libmio.dylib.so",
    "libpdl_runtime.dylib.so",
]
# Runtime Rust já presente em /system/lib64 do Lineage; não duplicar no vendor.
SYSTEM_RUST_LIBS = {
    "libstd.dylib.so",
    "liblogger.dylib.so",
    "liblog_rust.dylib.so",
    "libtokio.dylib.so",
    "libbinder_rs.dylib.so",
    "libandroid_logger.dylib.so",
    "libenv_filter.dylib.so",
    "libsignal_hook_registry.dylib.so",
    "libsocket2.dylib.so",
    "liberrno.dylib.so",
}
BT_REMOVE = [
    "bin/hw/android.hardware.bluetooth-service.default",
    "etc/init/bluetooth-service-default.rc",
    "etc/vintf/manifest/bluetooth-service-default.xml",
]
BT_CONTEXT = "u:object_r:hal_bluetooth_default_exec:s0"
VENDOR_FILE_CONTEXT = "u:object_r:vendor_file:s0"
VENDOR_CONFIG_CONTEXT = "u:object_r:vendor_configs_file:s0"
SERVICE_CONTEXT_LINE = (
    "android.desktop.bluetooth.hcihal.IHciTool/default "
    "u:object_r:hal_bluetooth_service:s0"
)

UCM_VERB = "etc/alsa/ucm2/Intel/sof-hda-dsp/HiFi.conf"
UCM_SPK = "etc/alsa/ucm2/HDA/HiFi-spk.conf"
UCM_ANALOG = "etc/alsa/ucm2/HDA/HiFi-analog.conf"


def log(msg):
    print(f">> {msg}")


def warn(msg):
    print(f"AVISO: {msg}", file=sys.stderr)


def die(msg):
    print(f"ERRO: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read_text(path, errors="strict"):
    with open(path, "r", errors=errors) as f:
        return f.read()


def write_text(path, text):
    with open(path, "w") as f:
        f.write(text)


def set_selinux(path, context):
    try:
        os.setxattr(path, b"security.selinux", context.encode() + b"\x00")
        return True
    except OSError as e:
        warn(f"não consegui aplicar SELinux {context} em {path}: {e}")
        return False


def copy_selinux(src, dst):
    try:
        val = os.getxattr(src, b"security.selinux")
    except OSError:
        return False
    try:
        os.setxattr(dst, b"security.selinux", val)
        return True
    except OSError:
        return False


def copy_file(src, dst, mode, context=None, keep_context=True):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        os.chmod(dst, 0o644)  # permite sobrescrever arquivo somente-leitura
    shutil.copy2(src, dst)
    os.chmod(dst, mode)
    ok = keep_context and copy_selinux(src, dst)
    if not ok and context:
        set_selinux(dst, context)
    return dst


def readelf_needed(path):
    if not os.path.isfile(path):
        return []
    with open(path, "rb") as f:
        magic = f.read(4)
    if magic != b"\x7fELF":
        return []
    for tool in ("readelf", "llvm-readelf"):
        if shutil.which(tool):
            try:
                out = subprocess.check_output([tool, "-d", path], text=True, stderr=subprocess.DEVNULL)
            except subprocess.CalledProcessError:
                return []
            return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", out)
    warn("readelf/llvm-readelf ausente; closure de dylibs não será verificada")
    return []


def patch_hwc(root):
    prop = os.path.join(root, "build.prop")
    if not os.path.isfile(prop):
        die(f"sem build.prop em {root}")
    os.chmod(prop, 0o644)
    lines = read_text(prop).splitlines()
    out, changed = [], 0
    dropped_hwc = False
    for ln in lines:
        if ln.startswith("ro.boot.hwc_apex="):
            dropped_hwc = True
            continue
        if ln.startswith("# OVERRIDE (issue #3): force drmfb-composer3"):
            dropped_hwc = True
            continue
        if ln.startswith("ro.surface_flinger.enable_frame_rate_override="):
            if ln != "ro.surface_flinger.enable_frame_rate_override=true":
                out.append("ro.surface_flinger.enable_frame_rate_override=true")
                changed += 1
            else:
                out.append(ln)
            continue
        out.append(ln)
    if not any(x.startswith("ro.surface_flinger.enable_frame_rate_override=") for x in out):
        out += ["", "####################################",
                "# OVERRIDE (issue #3): enable frame rate override (root cause fix)",
                "ro.surface_flinger.enable_frame_rate_override=true"]
        changed += 1
    if dropped_hwc:
        changed += 1
    write_text(prop, "\n".join(out) + "\n")
    log(f"hwc: build.prop atualizado ({changed} mudança(s); hwc_apex removido)")


def _insert_after(lines, needle, block):
    out, done = [], False
    for ln in lines:
        out.append(ln)
        if not done and ln.strip() == needle:
            out.extend(block)
            done = True
    return out, done


def _insert_before(lines, needle, block):
    out, done = [], False
    for ln in lines:
        if not done and ln.strip() == needle:
            out.extend(block)
            done = True
        out.append(ln)
    return out, done


def patch_ucm(root):
    verb = os.path.join(root, UCM_VERB)
    spk = os.path.join(root, UCM_SPK)
    analog = os.path.join(root, UCM_ANALOG)
    for f in (verb, spk, analog):
        if not os.path.isfile(f):
            die(f"UCM ausente: {f}")

    # Remove blocos legados (sem sentinela) e os novos (com sentinela).
    # Remove também os csets de volume do fix antigo; eles são re-inseridos.
    cset_vol = re.compile(r"cset \"name='(Master|Speaker|Headphone) Playback Volume'")

    def clean(lines):
        out = []
        for ln in lines:
            s = ln.strip()
            if s in ("# BEGIN NO-SOUND FIX", "# END NO-SOUND FIX"):
                continue
            if s.startswith("# NO-SOUND FIX (2026-11-08):"):
                continue
            if s == "# --> NO-SOUND FIX marker (2026-11-08) <--":
                continue
            if cset_vol.search(s):
                continue
            out.append(ln)
        return out

    # A) SectionVerb
    lines = clean(read_text(verb).splitlines())
    block = [
        "\t\t# BEGIN NO-SOUND FIX",
        "\t\t# ALC256 cold-boot DAC amp default ~20% (-52.5 dB); o HAL nunca",
        "\t\t# inicializa o mixer do card analógico. Força os DACs a full scale.",
        "\t\tcset \"name='Master Playback Volume' 100%\"",
        "\t\tcset \"name='Speaker Playback Volume' 100%\"",
        "\t\tcset \"name='Headphone Playback Volume' 80%\"",
        "\t\t# END NO-SOUND FIX",
    ]
    lines, done = _insert_after(lines, "EnableSequence [", block)
    if not done:
        die(f"EnableSequence não encontrado em {verb}")
    write_text(verb, "\n".join(lines) + "\n")

    # B) Speaker
    lines = clean(read_text(spk).splitlines())
    block = [
        "\t\t\t\t# BEGIN NO-SOUND FIX",
        "\t\t\t\tcset \"name='Speaker Playback Volume' 100%\"",
        "\t\t\t\t# END NO-SOUND FIX",
    ]
    lines, done = _insert_before(lines, "cset \"name='Speaker Playback Switch' on\"", block)
    if not done:
        die(f"'Speaker Playback Switch' não encontrado em {spk}")
    write_text(spk, "\n".join(lines) + "\n")

    # C) Headphones
    lines = clean(read_text(analog).splitlines())
    block = [
        "\t\t\t\t\t# BEGIN NO-SOUND FIX",
        "\t\t\t\t\tcset \"name='Headphone Playback Volume' 80%\"",
        "\t\t\t\t\t# END NO-SOUND FIX",
    ]
    lines, done = _insert_before(lines, "cset \"name='Headphone Playback Switch' on\"", block)
    if not done:
        die(f"'Headphone Playback Switch' não encontrado em {analog}")
    write_text(analog, "\n".join(lines) + "\n")
    log("ucm: DACs forçados em verb/speaker/headphones")


def patch_vulkan(root, xmldir):
    dest = os.path.join(root, "etc/permissions")
    os.makedirs(dest, exist_ok=True)
    for name in VULKAN_XMLS:
        src = os.path.join(xmldir, name)
        if not os.path.isfile(src):
            die(f"XML Vulkan ausente: {src}")
        dst = os.path.join(dest, name)
        copy_file(src, dst, 0o644, VENDOR_CONFIG_CONTEXT, keep_context=False)
    log(f"vulkan: {len(VULKAN_XMLS)} XMLs instalados em etc/permissions")


def _find_lib(root, name):
    for d in ("lib64", "lib"):
        p = os.path.join(root, d, name)
        if os.path.isfile(p):
            return p
    return None


def patch_bt(root, source):
    bin_src = os.path.join(source, BT_BIN)
    if not os.path.isfile(bin_src):
        die(f"source não parece um vendor do gbOS86 (sem {BT_BIN}): {source}")

    removed = 0
    for rel in BT_REMOVE:
        p = os.path.join(root, rel)
        if os.path.exists(p):
            os.unlink(p)
            removed += 1
    log(f"bt: {removed} arquivo(s) do HAL UART removidos")

    copy_file(bin_src, os.path.join(root, BT_BIN), 0o755, BT_CONTEXT)

    libs = list(BT_LIBS)
    for rel in BT_CONFIGS:
        src = os.path.join(source, rel)
        if os.path.isfile(src):
            copy_file(src, os.path.join(root, rel), 0o644, VENDOR_CONFIG_CONTEXT)
        else:
            warn(f"bt: config ausente na origem: {rel}")

    copied = set()
    queue = [BT_BIN] + list(BT_CONFIGS) + list(BT_LIBS)
    seen = set()
    while queue:
        rel = queue.pop()
        if rel in seen:
            continue
        seen.add(rel)
        if rel in BT_LIBS:
            src = _find_lib(source, rel)
            dst = _find_lib(root, rel)
            if src is None:
                if dst is None:
                    warn(f"bt: dylib listada não encontrada na origem: {rel}")
                continue
            if dst is None or os.path.getsize(dst) != os.path.getsize(src):
                copy_file(src, os.path.join(root, "lib64", rel), 0o644,
                          VENDOR_FILE_CONTEXT)
                copied.add(rel)
            dst = os.path.join(root, "lib64", rel)
        else:
            dst = os.path.join(root, rel)
        for need in readelf_needed(dst):
            if need in seen or need.startswith("libc.so") or need.startswith("libm.so"):
                continue
            if need in SYSTEM_RUST_LIBS:
                continue
            if _find_lib(root, need):
                continue
            if _find_lib(source, need):
                queue.append(need)
                libs.append(need)
            else:
                warn(f"bt: dependência {need} não existe no vendor de origem nem no alvo")

    sc = os.path.join(root, "etc/selinux/vendor_service_contexts")
    os.makedirs(os.path.dirname(sc), exist_ok=True)
    text = read_text(sc) if os.path.isfile(sc) else ""
    if SERVICE_CONTEXT_LINE not in text:
        with open(sc, "a") as f:
            if text and not text.endswith("\n"):
                f.write("\n")
            f.write(SERVICE_CONTEXT_LINE + "\n")
        log("bt: linha IHciTool acrescentada em vendor_service_contexts")

    log(f"bt: HAL desktop instalado ({len(copied)} dylib(s) copiada(s))")


def check(root, want_bt=False, want_vulkan=False, want_hwc=False, want_ucm=False):
    res = {}
    prop = os.path.join(root, "build.prop")
    prop_text = read_text(prop) if os.path.isfile(prop) else ""
    res["hwc_frame_rate_override"] = \
        "ro.surface_flinger.enable_frame_rate_override=true" in prop_text
    res["hwc_apex_override"] = "ro.boot.hwc_apex=" in prop_text
    perms = os.path.join(root, "etc/permissions")
    res["vulkan_xmls"] = sorted(
        x for x in VULKAN_XMLS if os.path.isfile(os.path.join(perms, x))
    ) if os.path.isdir(perms) else []
    res["bt_desktop"] = os.path.isfile(os.path.join(root, BT_BIN))
    res["bt_uart_default"] = os.path.isfile(os.path.join(root, BT_REMOVE[0]))
    manifests = os.path.join(root, "etc/vintf/manifest")
    providers = []
    if os.path.isdir(manifests):
        for name in os.listdir(manifests):
            p = os.path.join(manifests, name)
            if os.path.isfile(p) and "IBluetoothHci" in read_text(p, errors="replace"):
                providers.append(name)
    res["bt_vintf_providers"] = sorted(providers)
    sc = os.path.join(root, "etc/selinux/vendor_service_contexts")
    res["bt_service_context"] = os.path.isfile(sc) and SERVICE_CONTEXT_LINE in read_text(sc)
    # Só os labels dos arquivos que tocamos; não varre a árvore inteira.
    labels = {}
    for rel, want in [(BT_BIN, BT_CONTEXT)] + \
                     [(f"lib64/{x}", VENDOR_FILE_CONTEXT) for x in BT_LIBS] + \
                     [(x, VENDOR_CONFIG_CONTEXT) for x in BT_CONFIGS]:
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            try:
                labels[rel] = os.getxattr(p, b"security.selinux").decode(errors="replace").rstrip("\x00")
            except OSError:
                labels[rel] = None
    res["selinux_labels"] = labels
    ucm_missing = [f for f in (UCM_VERB, UCM_SPK, UCM_ANALOG) if not os.path.isfile(os.path.join(root, f))]
    res["ucm_files_missing"] = ucm_missing

    failures = []
    if want_hwc and not (res["hwc_frame_rate_override"] and not res["hwc_apex_override"]):
        failures.append("fix HWC/frame-rate ausente ou hwc_apex presente")
    if want_vulkan and len(res["vulkan_xmls"]) < 5:
        failures.append(f"XMLs Vulkan: {len(res['vulkan_xmls'])} (esperado 5)")
    if want_bt:
        if not res["bt_desktop"] or res["bt_uart_default"]:
            failures.append("HAL desktop ausente ou HAL UART ainda presente")
        if len(res["bt_vintf_providers"]) != 1:
            failures.append(f"providers VINTF IBluetoothHci: {res['bt_vintf_providers']} (esperado 1)")
        if not res["bt_service_context"]:
            failures.append("linha IHciTool ausente em vendor_service_contexts")
        bad = {k: v for k, v in res["selinux_labels"].items() if v is None}
        if bad:
            failures.append(f"labels SELinux ausentes: {list(bad)[:3]}")
    if want_ucm and ucm_missing:
        failures.append(f"arquivos UCM ausentes: {ucm_missing}")

    print(json.dumps(res, indent=2, sort_keys=True))
    if failures:
        die("check falhou: " + "; ".join(failures))
    print("check OK")


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("hwc", "ucm"):
        p = sub.add_parser(name)
        p.add_argument("root")
    p = sub.add_parser("vulkan")
    p.add_argument("root")
    p.add_argument("xmldir")
    p = sub.add_parser("bt")
    p.add_argument("root")
    p.add_argument("source")
    p = sub.add_parser("check")
    p.add_argument("root")
    p.add_argument("--bt", action="store_true")
    p.add_argument("--vulkan", action="store_true")
    p.add_argument("--hwc", action="store_true")
    p.add_argument("--ucm", action="store_true")
    args = ap.parse_args()
    if args.cmd == "hwc":
        patch_hwc(args.root)
    elif args.cmd == "ucm":
        patch_ucm(args.root)
    elif args.cmd == "vulkan":
        patch_vulkan(args.root, args.xmldir)
    elif args.cmd == "bt":
        patch_bt(args.root, args.source)
    else:
        check(args.root, args.bt, args.vulkan, args.hwc, args.ucm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
