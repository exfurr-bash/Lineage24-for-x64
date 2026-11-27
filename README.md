# Lineage24-for-x64

Build scripts and documentation for a modified LineageOS 24.0 live ISO on
x86_64. The default source set is the public 20261020 Generic_X86_64 release,
the pinned gbOS86 downloader and Google recovery, plus the Android common
kernel and KernelSU sources.

The project can build a KernelSU kernel, patch vendor images for Vulkan and
Bluetooth, inject a minimal GApps set into a separate system image, create an
ISO, and boot that ISO in QEMU. Source pins and provenance are listed in
[docs/SOURCES.md](docs/SOURCES.md). The later 20261122 release is documented
as a migration target only; see [docs/MIGRATION-20261122.md](docs/MIGRATION-20261122.md).

## Quick start

Use a Linux host with enough free disk space for the ISO, recovery image,
kernel build, extracted images, and temporary files. The default temporary
directory is $HOME/tmp/opencode.

~~~sh
cp config.env.example config.env
make bootstrap
make fetch PROFILE=gapps
make kernel
make vendor
make install
make iso
make test-qemu
~~~

The install target above prepares .ksu artifacts in the workspace. It does
not change the bootloader. Run the QEMU check before using
**make apply-boot**, which updates the GRUB configuration named by GRUB_CFG.

For the GApps ISO, use **make iso-gapps**. The build keeps the stock system image
unchanged and writes the GApps image separately. GApps are downloaded from
the pinned public sources and are not included in this repository. Review
[docs/RELEASES.md](docs/RELEASES.md) before publishing an ISO that contains
Google binaries.

Useful commands:

| Command | Purpose |
| --- | --- |
| make fetch PROFILE=gapps | Download and verify the pinned ISO and gbOS86 inputs |
| make kernel | Fetch pinned kernel and KernelSU sources, then build |
| make vendor | Create patched vendor images in the workspace |
| make gapps | Create a separate GApps system image |
| make iso / make iso-gapps | Create a live ISO |
| make test-qemu | Check an ISO in QEMU |
| make release ISO=... TAG=... | Split the ISO and generate checksums |
| make apply-boot | Add the prepared boot entry after QEMU validation |

Run **make help** for variables and options. See
[docs/KSU-prep.md](docs/KSU-prep.md) for the historical technical investigation
and [docs/RELEASES.md](docs/RELEASES.md) for release packaging.

## Licenses

Project scripts, original configuration, and documentation are GPL-2.0-only.
Downloaded operating-system images, Google binaries, and other upstream
components keep their own licenses and notices. See [LICENSE](LICENSE),
[NOTICE](NOTICE), and [vendor-vulkan-xmls/README.md](vendor-vulkan-xmls/README.md).

---

## Português (Brasil)

Este repositório reúne scripts e documentação para gerar uma ISO live
modificada do LineageOS 24.0 para x86_64. A base padrão é a release pública
Generic_X86_64 de 20261020, junto com o downloader pinado do gbOS86 e a
recovery pública do Google. O kernel Android common e o KernelSU também são
obtidos de suas fontes públicas.

O projeto compila um kernel com KernelSU, aplica os ajustes de Vulkan e
Bluetooth às imagens vendor, injeta um conjunto mínimo de GApps em uma imagem
system separada, cria a ISO e testa o boot no QEMU. Os pins e a procedência
das fontes estão em [docs/SOURCES.md](docs/SOURCES.md). A release 20261122
está documentada somente como alvo de migração futura em
[docs/MIGRATION-20261122.md](docs/MIGRATION-20261122.md).

### Começo rápido

Use Linux e reserve espaço para a ISO, a recovery, o build do kernel, as
imagens extraídas e os temporários. Por padrão, os temporários ficam em
$HOME/tmp/opencode.

~~~sh
cp config.env.example config.env
make bootstrap
make fetch PROFILE=gapps
make kernel
make vendor
make install
make iso
make test-qemu
~~~

O alvo install prepara os artefatos .ksu no workspace e não altera o
bootloader. Depois de validar a ISO no QEMU, **make apply-boot** atualiza a
entrada GRUB definida em GRUB_CFG.

Para gerar a ISO com GApps, use **make iso-gapps**. A imagem system original
continua preservada; a imagem com GApps é gerada separadamente. As GApps são
baixadas das fontes públicas pinadas e não estão neste repositório. Antes de
publicar uma ISO com binários do Google, leia
[docs/RELEASES.md](docs/RELEASES.md).

| Comando | Finalidade |
| --- | --- |
| make fetch PROFILE=gapps | Baixa e verifica a ISO e as fontes gbOS86 pinadas |
| make kernel | Baixa as fontes pinadas do kernel e KernelSU e compila |
| make vendor | Gera imagens vendor ajustadas no workspace |
| make gapps | Gera uma imagem system separada com GApps |
| make iso / make iso-gapps | Gera uma ISO live |
| make test-qemu | Verifica uma ISO no QEMU |
| make release ISO=... TAG=... | Divide a ISO e gera checksums |
| make apply-boot | Adiciona a entrada de boot após validação no QEMU |

Use **make help** para ver as opções. O histórico técnico está em
[docs/KSU-prep.md](docs/KSU-prep.md).

### Licenças

Os scripts, configurações originais e documentação deste projeto usam
GPL-2.0-only. Imagens baixadas, binários do Google e outros componentes
upstream mantêm suas próprias licenças e avisos. Consulte [LICENSE](LICENSE),
[NOTICE](NOTICE) e [vendor-vulkan-xmls/README.md](vendor-vulkan-xmls/README.md).
