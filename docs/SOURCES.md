# Fontes e pins

O build padrão usa a release 20261020. Os arquivos são baixados durante
**make fetch**; hashes de assets e commits estão em **config/sources.lock**.
Nenhuma imagem do SSD do desenvolvedor é entrada necessária do build.

## ISO base

| Item | Pin |
| --- | --- |
| Repositório | [IzumiSenaSora/Generic_X86_64](https://github.com/IzumiSenaSora/Generic_X86_64) |
| Release | lineage-24.0-20261020-UNOFFICIAL-0xCAFEBABE-Generic_x86_64-live |
| Partes | lineage-24.0_aa, lineage-24.0_ab |
| SHA-256 aa | b42ebd16f855cb1314194bb065557a738443ce8920955ae1d3aa146aa93cc901 |
| SHA-256 ab | 7013b32d12390e7f985b5d66018644cfff9057ce3405257f8bad83dbc6464ff0 |
| Kernel upstream | Android common 7.2, commit a2a0ccf4c10574fde950e554abffd9bdc9aec676 |

fetch_sources.sh valida cada parte antes de juntá-las. BASE_ISO_SHA256 pode
ser preenchido após calcular e revisar o hash do arquivo unido.

## Kernel e KernelSU

| Item | Pin |
| --- | --- |
| Kernel | [android.googlesource.com/kernel/common](https://android.googlesource.com/kernel/common), commit a2a0ccf4c10574fde950e554abffd9bdc9aec676 |
| KernelSU | [tiann/KernelSU](https://github.com/tiann/KernelSU), tag v3.3.1, commit 0c0fdb960178fa12d80d6cbcfdcb6ad8be6a865d |
| Configuração do kernel | Extraída com extract-ikconfig do kernel da ISO base baixada |

scripts/fetch_kernel.sh prepara os clones e confere os pins do lock. Patches
extras do Lineage são opcionais e não vêm de um caminho local fixo.

## gbOS86 e recovery do Google

O repositório gbOS86 não publica imagens de sistema em suas releases do
GitHub. O projeto baixa a recovery pública do Google e chama o downloader do
gbOS86 no commit pinado para extrair as partições necessárias.

| Item | Pin |
| --- | --- |
| Repositório | [linuxkid473/gbos-x86](https://github.com/linuxkid473/gbos-x86) |
| Commit | 8963af72be05b8e69dd997c11352a6cb4d6b70d0 |
| Build | CL3B.260622.276.R5, build id 16693588 |
| Recovery | [Google recovery.zip](https://dl.google.com/device/recovery/lapis-user/16693588/recovery.zip) |
| SHA-256 | 11fa52682aac5372ff0d149c7b64c6e165024265b292a5e6d0ba9c6ec936b351 |
| Partições | vendor_a, product_a, system_ext_a |

O downloader do gbOS86 requer o módulo lp_extract do próprio clone. O build
não copia código desse repositório, cuja licença não está declarada.

## Alternativa com GApps já incluídas

O perfil github-gapps baixa a imagem GApps da release pública de 20260914
do Generic_X86_64. Ela é anterior à base principal e não inclui o HAL
Bluetooth desktop. Use o perfil gapps para o caminho padrão deste projeto.

| Item | Pin |
| --- | --- |
| Release | lineage-24.0-20260914-0xCAFEBABE-Generic_x86_64-system-with-gapps |
| SHA-256 aa | 07060d8c7d9cfe54e0fbddf8a10172ca02d9beef003b62c3331b8a8213e44da |
| SHA-256 ab | f16ebba02572fafe5e0fbddf8a10172ca02d9beef003b62c3331b8a8213e44da |
| Imagem unida | 596b9d6f7ef836000becfa8ba99cf32e254f6a376d14b7d520acdd8b1b6cce1d |

GApps não são redistribuídos por este repositório. Veja
[docs/RELEASES.md](RELEASES.md).

## XMLs de permissões Vulkan

Os cinco XMLs versionados em vendor-vulkan-xmls/ têm cabeçalhos e avisos
Apache-2.0 do Android Open Source Project. A origem upstream é
[frameworks/native/data/etc](https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-security-17.0.0_r2/data/etc);
as correspondências entre nomes .prebuilt.xml e fontes .xml estão em
[vendor-vulkan-xmls/README.md](../vendor-vulkan-xmls/README.md). Os hashes
locais estão registrados em config/sources.lock.

## Temporários

Scripts e testes usam $HOME/tmp/opencode por padrão. O caminho pode ser
alterado em config.env com TMPROOT. Não use /tmp/opencode.
