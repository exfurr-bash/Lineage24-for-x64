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
**Verified in daily use (2026-11-11)**: 15+ boots logged, KernelSU active on
every one, `hardware_detect` consistently picks the Intel/ANV path, **0 mount
failures**, and the owner reports no issues on the device.

**New (2026-11-11): GApps variant.** A third ISO, `…-live-ksu-vulkan-gapps.iso`,
is the same KernelSU + Vulkan build with the Google apps extracted from
Google's official Android x86 build ("gbOS86"): Play Services
(`PrebuiltGmsCore`), Play Store (`Phonesky`), Google Services Framework and the
`com.google.android.gmssystem` APEX. Both systems are Android 17 (SDK 37) with
identical ABI lists, so the apps drop in as-is — only the SELinux labels were
applied. Validated in QEMU (full boot, 55 APEXes activated, 0 crashes, plus an
interactive graphical session ended by a clean in-Android shutdown) and also
injected into the installed system on the SSD (stock `system.img` kept as
`system.img.stock` for rollback). Full details in [`KSU-prep.md`](KSU-prep.md) (pt-BR).

**2026-11-11 — Bluetooth root-caused.** The Bluetooth toggle doesn't work on
x86 hardware: the build ships the AOSP **UART (H4) default HAL**, which cannot
drive USB-attached controllers (e.g. this machine's Intel AX201 `8087:0026`) —
the HAL aborts (`FORTIFY: FD_SET: fd -1 < 0`) and takes the Bluetooth stack
down with it. Google's official x86 build ships a **Rust
`bluetooth-service.desktop` HAL** made for exactly this class of hardware
(same `IBluetoothHci/default` AIDL — a drop-in swap). The kernel side is
already complete (`btusb.ko` + `btintel.ko` present; `firmware.img` already
carries `intel/ibt-0040-4150.sfi/.ddc`). Fix mapped — vendor repack porting
the desktop HAL from the official build; details in `KSU-prep.md` ("Fase 5").

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
**Verificado em uso real (11/11/2026)**: 15+ boots registrados, KernelSU ativo
em todos, `hardware_detect` escolhendo o caminho Intel/ANV consistentemente,
**0 falhas de montagem** — relato do dono: nenhum problema no dispositivo.

**Novo (11/11/2026): variante com GApps.** Uma terceira ISO,
`…-live-ksu-vulkan-gapps.iso`, é o mesmo build KernelSU + Vulkan com os apps
Google extraídos do build oficial do Android x86 da Google ("gbOS86"): Play
Services (`PrebuiltGmsCore`), Play Store (`Phonesky`), Google Services
Framework e o APEX `com.google.android.gmssystem`. Os dois sistemas são
Android 17 (SDK 37) com abilist idêntica — os apps entram como estão, só com
os labels SELinux aplicados. Validado no QEMU (boot completo, 55 apexes,
0 crashes, sessão gráfica interativa com shutdown limpo pelo Android) e
injetado também no sistema instalado do SSD (stock preservado como
`system.img.stock` para rollback). Detalhes completos no
[`KSU-prep.md`](KSU-prep.md).

**Bluetooth — causa raiz encontrada (11/11/2026).** O toggle de BT não
funciona em hardware x86: o build traz o HAL AOSP **default orientado a
UART (H4)**, que não consegue dirigir controllers **USB** (neste máquina,
Intel AX201 `8087:0026`) — o HAL aborta (`FORTIFY: FD_SET: fd -1 < 0`) e leva
o stack de BT junto. O build oficial x86 da Google traz um HAL próprio em
**Rust** (`bluetooth-service.desktop`), feito exatamente para essa classe de
hardware, com o **mesmo AIDL** `IBluetoothHci/default` — troca drop-in. O
lado kernel já está completo (`btusb.ko` + `btintel.ko` presentes;
`firmware.img` já traz `intel/ibt-0040-4150.sfi/.ddc`). Fix mapeado — repack
do vendor portando o HAL desktop do build oficial; detalhes no
`KSU-prep.md` ("Fase 5").

### Downloads (releases)

| Asset | O quê |
|---|---|
| `*-live-ksu-vulkan.iso_aa/.iso_ab` | ISO live **modificada** (KernelSU + Vulkan). Junte com `cat …_aa …_ab > file.iso` |
| `*-live-ksu-vulkan-gapps.iso_aa/.iso_ab/.iso_ac` | ISO live **modificada + GApps** (KernelSU + Vulkan + Play Store/Serviços do Google). Junte com `cat …_aa …_ab …_ac > file.iso` |
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

### Variante GApps (ISO `*-gapps.iso`)

Idêntica à ISO `ksu-vulkan`, com o `system.img` substituído pelo repack
EROFS que contém os GApps do build oficial do Google Android x86 ("gbOS86",
partições do `super.img` lidas **read-only**):

| Conteúdo injetado | Origem |
|---|---|
| `product/priv-app/PrebuiltGmsCore` (Play Services) | `product_a` |
| `product/priv-app/Phonesky` (Play Store) | `product_a` |
| `system_ext/priv-app/GoogleServicesFramework` | `system_ext_a` |
| `privapp-permissions-google-p/-se.xml`, `split-permissions-google.xml` | `product_a` / `system_ext_a` |
| `sysconfig google*.xml` + `allowed_apex_…gmssystem.xml` | `product_a` |
| `system/apex/com.google.android.gmssystem.prodvic.apex` | `product_a` |

gbOS86 e Lineage 24.0 são ambos Android 17 (SDK 37) com abilist
`x86_64,arm64-v8a` — nenhum APK foi reconstruído; só os labels SELinux foram
aplicados (xattrs byte-exatos do `system.img` original + `matchpathcon` para
os arquivos novos). No primeiro boot depois do flash/injeção o GMS faz o
setup (dexopt) — mais demorado; depois disso normal. Play Store precisa de
login de conta Google para uso completo.

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
- Gbos86: [linuxkid473/gbos-x86](https://github.com/linuxkid473/gbos-x86)
- ISO original inclusa nos releases **sem modificações**, crédito ao projeto original
