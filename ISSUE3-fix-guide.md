# Guia de correção do bootloop — issue #3 (Generic x86_64 / LineageOS 24.0)

> **Estado: CORRIGIDO E VERIFICADO EM MÁQUINA REAL** (2026-11-08).
> AESSE guia substitui a versão anterior, que culpava o composer
> `drm_hwcomposer_upstream` — teoria desprovada (o `drmfb` forçado crashava igual).

## TL;DR

O bootloop **não** é do composer nem do driver GPU. O device tree do Generic x86_64
despacha todo build com:

```
ro.surface_flinger.enable_frame_rate_override=false   # configs/properties/vendor.prop:21
```

O painel interno (eDP) reporta **60.003117 Hz** (não 60.0 exato). O DMS valida o modo com
tolerância Java `0.01 Hz` (aceita) e passa ao SurfaceFlinger o range de render
`[0, 60.0]` (padrão do `config_defaultPeakRefreshRate` = 60). O SF valida com épsilon C++
`0.001 Hz` (`Fps::isApproxEqual`) → `60.003117 − 60.0 = 0.003117 > 0.001` → único modo
do display rejeitado → zero modos → `LOG_ALWAYS_FATAL` no
`RefreshRateSelector::constructAvailableRefreshRates` → SIGABRT → bootloop.

O retry "even after ignoring the render range" não ignora nada quando o override está
desligado (o lambda `filterModes` continua capturando o `ranges.render` externo) — por
isso o fatal é inevitável.

**Correção (1 linha) em `/vendor/build.prop`:**

```
ro.surface_flinger.enable_frame_rate_override=true
```

## Como aplicar

### 1. Patch do vendor.img (ERFS extract → sed → repack)

Script pronto e idempotente:

```sh
sudo /home/iris/android17/patch_vendor_hwc.sh /caminho/da/android-dir/vendor.img
# sem argumento: varre partições procurando imgs/vendor.img
```

O patch (ferramentas em `extracted/erofs-inst/bin`):

1. extrai a imagem EROFS preservando dono/permissões/xattrs SELinux;
2. vira `ro.surface_flinger.enable_frame_rate_override=false` → `true` (injeta se ausente);
3. mantém/removes `ro.boot.hwc_apex=2` conforme flag do script — **irrelevante para o fix**
   (composer é neutro no crash; mantenha só se quiser o drmfb);
4. reempacota com `mkfs.erofs -zlz4 --mount-point=/vendor --preserve-mtime -T <ts original>`;
5. monta em loop e valida as linhas antes de trocar o arquivo (backup `.orig`);

Sem AVB no vendor.img + `androidboot.selinux=permissive` no cmdline → repack seguro.

### 2. Boot e verificação

Boot normal (sem `nomodeset`). Verificação no sistema:

```sh
getprop ro.surface_flinger.enable_frame_rate_override   # true
dumpsys SurfaceFlinger | grep -i "frame_rate_override"  # enableFrameRateOverride true
```

Resultado medido: UI total funcional, sem bootloop, terminal Linux instalável.

## Referência da cadeia completa

Detalhada em **`issue3-root-cause.md`** (inglês, com trechos de código e números de linha
exatos de `RefreshRateSelector.cpp`, `Fps.h`, `VoteSummary.java`,
`DisplayModeDirector.java`, `SurfaceControl.java`, `SurfaceFlinger.cpp`):
tolerância Java 0.01 vs épsilon C++ 0.001; voto de render `[0, 60.0]` vindo de
`config_defaultPeakRefreshRate`; modo 60.003117 Hz dumpado em
`diag1/early_logcat.log:7968`; fatal em `:15581–15820`; composer neutro provado por
`Override hwc_apex from 1 to 2` (:15514 region) com crash idêntico.

## Por que `nomodeset` "consertava"

O fallback de framebuffer do kernel expõe modos de taxa inteira (60.000000 exato), que
passam no épsilon de 0.001 do SF. Não é uma correção — é trocar a entrada que dispara o bug.

## Recomendações para o upstream (projeto e AOSP)

1. **Projeto**: remover a linha de `configs/properties/vendor.prop` (default AOSP = true).
2. **AOSP (bugs para referenciar)**:
   - retry de "ignorar render range" inócuo com override off (captura de lambda) +
     `LOG_ALWAYS_FATAL` transformando artefato de arredondamento em bootloop;
   - inconsistência de tolerância Java 0.01 vs C++ 0.001 na fronteira DMS→SF;
   - bump do `maxRenderFrameRate` hoje só vale p/ displays externos — painéis internos
     fracionários (eDP) ficam de fora.
3. **Documentação**: `ro.boot.*` overrides (`hwc_apex` etc.) funcionam via kernel cmdline
   (`androidboot.hwc_apex=2`), só não estão documentados em `docs/boot-parameters.md`.

## Rollback

`vendor.img.orig` (estado anterior) fica do lado do `vendor.img`. Restaurar:
`sudo cp vendor.img.orig vendor.img`.

## Limpeza pós-debug (opcional)

- Restaurar CachyOS como primeiro boot:
  `sudo efibootmgr -o 0000,0003,0002,0001,0008,0006,0007`
- Espaço em `/home` (98%): avaliar apagar
  `extracted/lineage-24.0-persist-log.iso` (2.7 G) e `/tmp/opencode/*` — a instalação em
  p7 é independente da ISO.
- Pendrive USB (`sda`): ISO verificado por sha256 (`0e7bb5c5…07158`), mantém como rescue.
