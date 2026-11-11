# LineageOS 24.0 (Android 17) x86_64 — KernelSU + Vulkan

Modified **live ISOs** of the [Generic_X86_64](https://github.com/IzumiSenaSora/Generic_X86_64)
project (LineageOS 24.0 / Android 17, x86_64, mainline kernel `7.2.0+`) with:

1. **KernelSU** (v3.3.1, built-in — "Route A") integrated into the kernel
2. **Vulkan enabled** (the ROM ships feature XMLs only inside the *SwiftShader*
   APEX, so hardware-GPU devices never got `FEATURE_VULKAN` — fixed here by
   adding the 5 Vulkan feature XMLs to `/vendor/etc/permissions/`)

Built and tested on a Samsung Galaxy Book4 (i5-1335U, Intel Iris Xe `8086:a7a1`) —
the same hardware reported in [upstream issue #3](https://github.com/IzumiSenaSora/Generic_X86_64/issues/3).
GLES runs fully hardware-accelerated (Mesa/iris); with this build apps also see
**Vulkan 1.3 via Mesa ANV** (hardware).

---

## Versão em português

ISOs **live** modificadas do projeto Generic_X86_64 (LineageOS 24.0/Android 17,
x86_64, kernel mainline `7.2.0+`) com **KernelSU integrado ao kernel** (rota
builtin) e **Vulkan habilitado** (os XMLs de feature só existiam dentro do APEX
SwiftShader, então o `FEATURE_VULKAN` nunca era declarado — fix: 5 XMLs de
feature em `/vendor/etc/permissions/`). GLES já é 100 % acelerado por hardware
(Mesa/iris); com este build, apps também veem **Vulkan 1.3 via Mesa ANV**.

Testado em Samsung Galaxy Book4 (i5-1335U, Iris Xe `a7a1`) — o mesmo hardware
da issue #3 do projeto.

### Downloads (releases)

| Asset | O quê |
|---|---|
| `*-live-ksu-vulkan.iso_aa/.iso_ab` | ISO live **modificada** (KernelSU + Vulkan). Junte com `cat …_aa …_ab > file.iso` |
| `lineage-24.0.iso_aa/.iso_ab` | ISO **original** oficial 20261020 (re-host, sem modificações) |
| `sha256sums.txt` | Checksums de tudo |

Arquivos > 2 GiB não são aceitos como asset de release — por isso as ISOs estão
em partes (mesmo esquema dos releases oficiais). Após baixar:
`cat lineage-…-ksu-vulkan.iso_aa lineage-…-ksu-vulkan.iso_ab > lineage-…-ksu-vulkan.iso`
e confira com `sha256sum -c sha256sums.txt`.

### O que foi modificado (relativo à ISO oficial 20261020)

| Arquivo | Modificação |
|---|---|
| `kernel` | KernelSU builtin (syscall dispatcher x86_64), `CONFIG_EXT4_FS_SECURITY=y`/`POSIX_ACL=y` restaurados (bug upstream de regex no append de config), `X86_KERNEL_IBT=n`, `MODULE_ALLOW_BTF_MISMATCH=y` |
| `ramdisk-all-combined.img` | Módulos do ramdisk substituídos pelos rebuildados (653 trocados, 4 builtin removidos) |
| `vendor_dlkm.img` | 3973 módulos rebuildados + strip de `.BTF`/`.BTF.ext` |
| `vendor.img` | + 5 XMLs de feature Vulkan em `/vendor/etc/permissions/` (repack EROFS, sem assinatura — payloads de APEX são AVB-assinados e não podem ser editados) |
| `grub.cfg` | Títulos marcados "(KernelSU + Vulkan)" + entrada de diagnóstico `androidboot.vulkan_apex=2` |

Tudo documentado (com causa raiz, matriz de testes QEMU e logs) em
[`KSU-prep.md`](KSU-prep.md) (pt-BR).

### Scripts

| Script | O quê |
|---|---|
| `build_kernel_ksu.sh` | Compila o kernel 7.2.0+ com KSU builtin (guard de OOM swap-aware, `-j12`) |
| `install_kernel_ksu.sh` | Repack de `vendor_dlkm.ksu.img` + ramdisk + dir Android paralelo + entrada GRUB (idempotente; `--apply-boot`) |
| `install_vendor_vulkan.sh` | Repack do `vendor.img` com os XMLs de feature Vulkan (`--rollback` incluído) |
| `make_iso.sh` | Reconstrói a ISO live modificada a partir da ISO oficial + dir Android do SSD |
| `collect_bootloop_logs.sh` | Coleta `early_logcat.log`/bootstat após um bootloop |

### Como as ISOs são montadas

A ISO live do projeto boot a partir de GRUB (BIOS El Torito + EFI) com
`androidboot.live=1`, `mount_system=imgs`, `mount_userdata=tmpfs` (sem
persistência — cada boot é fresco). O `generic_init` encontra o dir
`android-Generic_x86_64/` no próprio dispositivo (testado em QEMU: no
CD-ROM `/dev/block/sr0`) — inclusive em pendrives Ventoy/loopback GRUB
(via `androidboot.android_iso_uuid`).

### Créditos / base

- Projeto original: [IzumiSenaSora/Generic_X86_64](https://github.com/IzumiSenaSora/Generic_X86_64)
  (device tree: [`me-cafebabe-aosp-mainline`](https://github.com/orgs/me-cafebabe-aosp-mainline/repositories))
- KernelSU: [tiann/KernelSU](https://github.com/tiann/KernelSU)
- ISO original inclusa nos releases **sem modificações**, crédito ao projeto original
