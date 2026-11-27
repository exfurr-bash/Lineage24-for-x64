#!/usr/bin/env python3
"""Testes unitários das bibliotecas em scripts/lib (sem root, sem EROFS)."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

os.environ.setdefault("TMPDIR", str(Path.home() / "tmp" / "opencode"))
Path(os.environ["TMPDIR"]).mkdir(parents=True, exist_ok=True)
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts" / "lib"


def load(name):
    spec = importlib.util.spec_from_file_location(name, LIB / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


cpio_rewrite = load("cpio_rewrite")
flatten_depmod = load("flatten_depmod")
grub_patch = load("grub_patch")
vendor_patches = load("vendor_patches")


def pad4(b: bytes) -> bytes:
    n = (-len(b)) % 4
    return b + (b"\x00" * n)


def newc(name: str, data: bytes, mode: int = 0o100644) -> bytes:
    nb = name.encode() + b"\x00"
    fields = [1, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0]
    hdr = b"070701" + b"".join(b"%08x" % f for f in fields)
    assert len(hdr) == 110
    return pad4(hdr + nb) + pad4(data)


def trailer() -> bytes:
    return newc("TRAILER!!!", b"")


class Temp(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="l24-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)


class CpioRewriteTest(Temp):
    def test_rewrite_and_prune(self):
        cpio = self.tmp / "rd.cpio"
        cpio.write_bytes(
            newc("lib/modules/a.ko", b"OLD-A")
            + newc("lib/modules/ext4.ko", b"BUILTIN")
            + newc("lib/modules/keep.ko", b"KEEP")
            + newc("lib/modules/sub/b.ko", b"OLD-B")
            + trailer()
        )
        mods = self.tmp / "mods"
        (mods / "sub").mkdir(parents=True)
        (mods / "a.ko").write_bytes(b"NEW-A")
        (mods / "sub" / "b.ko").write_bytes(b"NEW-B")
        out = self.tmp / "out.cpio"
        report = self.tmp / "report.json"
        # main() lê sys.argv; usa subprocess para exercitar a CLI de verdade.
        p = subprocess.run(
            [sys.executable, str(LIB / "cpio_rewrite.py"),
             "--cpio", str(cpio), "--modules-dir", str(mods),
             "--out", str(out), "--report", str(report)],
            capture_output=True, text=True,
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        data = out.read_bytes()
        recs = cpio_rewrite.parse(data)
        by = {r["name"].decode(): data[r["dat"]:r["dat"] + r["size"]] for r in recs}
        self.assertEqual(by["lib/modules/a.ko"], b"NEW-A")
        self.assertEqual(by["lib/modules/sub/b.ko"], b"NEW-B")
        self.assertEqual(by["lib/modules/keep.ko"], b"KEEP")
        self.assertNotIn("lib/modules/ext4.ko", by)
        self.assertEqual(sum(1 for r in recs if r["trailer"]), 1)
        rep = json.loads(report.read_text())
        self.assertEqual(rep["replaced"], 2)
        self.assertIn("ext4.ko", rep["builtin_removed"])
        self.assertIn("keep.ko", rep["missing"])

    def test_multiple_trailers(self):
        cpio = self.tmp / "rd2.cpio"
        cpio.write_bytes(newc("lib/modules/a.ko", b"A") + trailer()
                         + newc("lib/modules/c.ko", b"C") + trailer())
        mods = self.tmp / "m2"
        mods.mkdir()
        (mods / "a.ko").write_bytes(b"A2")
        (mods / "c.ko").write_bytes(b"C2")
        out = self.tmp / "o2.cpio"
        subprocess.run(
            [sys.executable, str(LIB / "cpio_rewrite.py"), "--cpio", str(cpio),
             "--modules-dir", str(mods), "--out", str(out)],
            check=True, capture_output=True,
        )
        recs = cpio_rewrite.parse(out.read_bytes())
        self.assertEqual(sum(1 for r in recs if r["trailer"]), 2)
        by = {r["name"].decode(): out.read_bytes()[r["dat"]:r["dat"] + r["size"]] for r in recs}
        self.assertEqual(by["lib/modules/a.ko"], b"A2")
        self.assertEqual(by["lib/modules/c.ko"], b"C2")


class FlattenDepmodTest(Temp):
    def setup_tree(self):
        root = self.tmp / "lib/modules/7.2.0+"
        flat = self.tmp / "flat"
        root.mkdir(parents=True)
        flat.mkdir()
        (flat / "foo.ko").write_bytes(b"f")
        (flat / "bar.ko").write_bytes(b"b")
        (root / "modules.builtin").write_text("kernel/drivers/baz.ko\n")
        (root / "modules.dep").write_text(
            "kernel/foo.ko: kernel/bar.ko kernel/drivers/baz.ko\n"
            "kernel/bar.ko:\n"
            "kernel/drivers/baz.ko:\n"
            "kernel/orphan.ko: kernel/foo.ko\n"
        )
        (root / "modules.alias").write_text(
            "alias usb:v1234p5678d* foo\n"
            "alias pci:v0000 foo\n"
            "alias builtin baz\n"
        )
        (root / "modules.softdep").write_text(
            "pre: foo bar baz\n"
            "post: baz\n"
        )
        load = flat / "modules.load"
        load.write_text("bar\n")
        return root, flat, load

    def test_flatten(self):
        root, flat, load = self.setup_tree()
        report = self.tmp / "r.json"
        p = subprocess.run(
            [sys.executable, str(LIB / "flatten_depmod.py"),
             "--modules-root", str(root), "--flat-dir", str(flat),
             "--modules-load", str(load), "--bt-modules", "foo btusb",
             "--allow-missing", "orphan.ko", "--report", str(report)],
            capture_output=True, text=True,
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        dep = (flat / "modules.dep").read_text().splitlines()
        self.assertEqual(set(dep), {"foo.ko: bar.ko", "bar.ko:"})
        self.assertEqual((flat / "modules.load").read_text().splitlines(), ["bar", "foo"])
        alias = (flat / "modules.alias").read_text()
        self.assertIn("alias usb:v1234p5678d* foo", alias)
        self.assertNotIn("builtin", alias)
        soft = (flat / "modules.softdep").read_text()
        self.assertIn("pre: foo bar", soft)
        rep = json.loads(report.read_text())
        self.assertEqual(rep["builtin_deps_pruned"], 1)
        self.assertEqual(rep["missing"], [])

    def test_missing_dependency_fails(self):
        root = self.tmp / "m"
        root.mkdir()
        (root / "modules.dep").write_text("kernel/foo.ko: kernel/nope.ko\n")
        flat = self.tmp / "f"
        flat.mkdir()
        (flat / "foo.ko").write_bytes(b"f")
        p = subprocess.run(
            [sys.executable, str(LIB / "flatten_depmod.py"),
             "--modules-root", str(root), "--flat-dir", str(flat)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("nope.ko", p.stderr + p.stdout)


class GrubPatchTest(Temp):
    CFG = '''\
menuentry "LineageOS 24.0 Live" {
    boot_android_with_default_mount_options androidboot.live=1
}
menuentry "LineageOS 24.0 (dbg, persistent data)" {
    linux /android-Generic_x86_64/kernel root=/dev/ram0 androidboot.android_dir=android-Generic_x86_64
    initrd /android-Generic_x86_64/ramdisk-all-combined.img
}
submenu "Advanced graphics options for LineageOS 24.0 Live" {
    menuentry "Force using Mesa llvmpipe graphics" {
        boot_android_with_default_mount_options androidboot.graphics=llvmpipe
    }
}
'''

    def test_titles_and_entry(self):
        cfg = self.tmp / "grub.cfg"
        cfg.write_text(self.CFG)
        grub_patch.iso_titles(str(cfg), "ksu")
        s = cfg.read_text()
        self.assertIn("LineageOS 24.0 Live (KernelSU + Vulkan)", s)
        self.assertIn("Select Vulkan APEX: swiftshader", s)
        grub_patch.iso_titles(str(cfg), "gapps")
        s = cfg.read_text()
        self.assertIn("KernelSU + Vulkan + GApps", s)
        # idempotente
        grub_patch.iso_titles(str(cfg), "gapps")
        self.assertEqual(s, cfg.read_text())

        cfg2 = self.tmp / "grub-entry.cfg"
        cfg2.write_text(self.CFG)
        grub_patch.entry(str(cfg2))
        s = cfg2.read_text()
        self.assertIn("kernel.ksu", s)
        self.assertIn("ramdisk-all-combined.ksu.img", s)
        self.assertIn("android_dir=android-Generic_x86_64-ksu", s)
        self.assertIn("LineageOS 24.0 (KSU, persistent data)", s)
        grub_patch.check_entry(str(cfg2))
        # idempotente: não duplica
        grub_patch.entry(str(cfg2))
        self.assertEqual(s, cfg2.read_text())


class VendorPatchesTest(Temp):
    def test_hwc_idempotent(self):
        root = self.tmp / "vendor"
        root.mkdir()
        prop = root / "build.prop"
        prop.write_text(
            "ro.surface_flinger.enable_frame_rate_override=false\n"
            "ro.boot.hwc_apex=2\n"
            "# OVERRIDE (issue #3): force drmfb-composer3\n"
        )
        vendor_patches.patch_hwc(str(root))
        vendor_patches.patch_hwc(str(root))
        text = prop.read_text()
        self.assertEqual(text.count("ro.surface_flinger.enable_frame_rate_override=true"), 1)
        self.assertNotIn("ro.boot.hwc_apex=", text)
        self.assertNotIn("# OVERRIDE (issue #3)", text)
        vendor_patches.check(str(root), want_hwc=True)

    def test_ucm_idempotent(self):
        root = self.tmp / "vendor"
        for rel in (vendor_patches.UCM_VERB, vendor_patches.UCM_SPK, vendor_patches.UCM_ANALOG):
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / vendor_patches.UCM_VERB).write_text(
            "SectionVerb {\n"
            "\tEnableSequence [\n"
            "\t\tcset \"name='Master Playback Volume' 100%\"\n"
            "\t]\n"
            "}\n"
        )
        (root / vendor_patches.UCM_SPK).write_text(
            "\t\tcset \"name='Speaker Playback Switch' on\"\n"
        )
        (root / vendor_patches.UCM_ANALOG).write_text(
            "\t\tcset \"name='Headphone Playback Switch' on\"\n"
        )
        for _ in range(2):
            vendor_patches.patch_ucm(str(root))
        verb = (root / vendor_patches.UCM_VERB).read_text()
        spk = (root / vendor_patches.UCM_SPK).read_text()
        analog = (root / vendor_patches.UCM_ANALOG).read_text()
        self.assertEqual(verb.count("# BEGIN NO-SOUND FIX"), 1)
        self.assertEqual(verb.count("Master Playback Volume"), 1)
        self.assertEqual(verb.count("Speaker Playback Volume"), 1)
        self.assertEqual(verb.count("Headphone Playback Volume"), 1)
        self.assertEqual(spk.count("Speaker Playback Volume"), 1)
        self.assertEqual(analog.count("Headphone Playback Volume"), 1)
        vendor_patches.check(str(root), want_ucm=True)

    def test_vulkan(self):
        root = self.tmp / "vendor"
        root.mkdir()
        xmldir = self.tmp / "xmls"
        xmldir.mkdir()
        for n in vendor_patches.VULKAN_XMLS:
            (xmldir / n).write_text("<permissions/>\n")
        vendor_patches.patch_vulkan(str(root), str(xmldir))
        vendor_patches.patch_vulkan(str(root), str(xmldir))
        vendor_patches.check(str(root), want_vulkan=True)


class GappsInjectTest(Temp):
    def test_root_layout(self):
        stock = self.tmp / "root"
        (stock / "system/apex").mkdir(parents=True)
        (stock / "system/etc/selinux").mkdir(parents=True)
        (stock / "system/etc/selinux/plat_file_contexts").write_text(
            "/system/apex(/.*)? u:object_r:system_file:s0\n"
            "/system(/.*)? u:object_r:system_file:s0\n"
            "/product(/.*)? u:object_r:system_file:s0\n"
            "/system_ext(/.*)? u:object_r:system_file:s0\n"
        )
        product = self.tmp / "product"
        for rel in ("priv-app/Phonesky", "priv-app/PrebuiltGmsCore",
                    "etc/permissions", "etc/sysconfig", "apex"):
            (product / rel).mkdir(parents=True, exist_ok=True)
        (product / "priv-app/Phonesky/Phonesky.apk").write_bytes(b"apk")
        (product / "priv-app/PrebuiltGmsCore/GmsCore.apk").write_bytes(b"gms")
        (product / "etc/permissions/privapp-permissions-google-p.xml").write_text("x")
        (product / "apex/com.google.android.gmssystem.prodvic.apex").write_bytes(b"apex")
        se = self.tmp / "system_ext"
        (se / "priv-app/GoogleServicesFramework").mkdir(parents=True)
        (se / "priv-app/GoogleServicesFramework/GSF.apk").write_bytes(b"gsf")
        (se / "etc/permissions").mkdir(parents=True)
        (se / "etc/permissions/privapp-permissions-google-se.xml").write_text("x")
        manifest = self.tmp / "m.json"
        p = subprocess.run(
            [sys.executable, str(LIB / "gapps_inject.py"),
             "--stock-tree", str(stock), "--product-tree", str(product),
             "--system-ext-tree", str(se), "--manifest", str(manifest)],
            capture_output=True, text=True,
        )
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertTrue((stock / "product/priv-app/Phonesky/Phonesky.apk").is_file())
        self.assertTrue((stock / "system_ext/priv-app/GoogleServicesFramework/GSF.apk").is_file())
        self.assertTrue((stock / "system/apex/com.google.android.gmssystem.prodvic.apex").is_file())
        rep = json.loads(manifest.read_text())
        self.assertEqual(rep["layout"], "root")
        self.assertGreaterEqual(rep["injected_count"], 4)


if __name__ == "__main__":
    unittest.main()
