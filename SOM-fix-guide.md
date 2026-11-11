# Guia de correção do "sem som" — Generic x86_64 / LineageOS 24.0 (ALC256)

> **Estado: CORRIGIDO E VERIFICADO EM MÁQUINA REAL** (2026-11-08).
> Hardware: Samsung NP750XGJ "Galaxy Book" (i5-1335U RPL-U), codec Realtek **ALC256**
> (`hdaudio:v10EC0256`), SOF machine driver `skl_hda_dsp_generic`, card 0 `sofhdadsp`.

## TL;DR

O som do **fone USB funcionava**, mas **caixas de som internas e fone P2 analógico ficavam
mudos**. Não era kernel, nem SOF, nem roteamento do AudioFlinger — tudo isso estava
saudável. A causa real:

1. **O estado frio (cold boot) da ALC256 deixa as DACs de playback a ~20%** (−52,5 dB →
   inaudível). É o valor de *factory default* do amp das DACs (nodes 0x02 speaker e 0x03
   headphone): `Amp-Out vals: [0x11 0x11]` = 17 de 87 passos × 0,75 dB/step = **−52,5 dB**.
2. **O Android nunca inicializa o mixer do card analógico.** No CachyOS, `alsactl restore`
   (systemd) grava `87 [100%] [0.00dB]` na DAC no boot — por isso o Linux "normal"
   funciona. O Android (kernel mainline) **não roda alsactl** e depende do HAL.
3. O HAL de áudio do projeto (**`MainlineAudio`**, APEX `com.android.hardware.audio.mainline`)
   só rota `InitializeMixer` (alsa-lib, que grava 100%) para **cards que aparecem depois do
   startup** (ex.: fone USB hot-plug → "card 1 playback=100%"). O card 0 analógico,
   presente no boot, **nunca** recebe a inicialização.
4. Prova em runtime (loop de 0,5 s no `/proc/asound/card0/codec#0` durante ~30 s): a DAC
   ficou **travada em `[0x11 0x11]` o tempo todo** — volume FN+F8 no máximo, volume −,
   plug/desplug do jack, tentativas de playback. **O Android nunca escreve no mixer
   analógico.** Os caminhos software (framework volume 25/25, curva do XML terminando em
   0 dB) estavam todos corretos.

O sinal chegava inteiro ao SOF (PCM rodando, position avançando, `xruns=0`) — mas saía do
codec atenuado em −52,5 dB: silêncio percebido. O HAL deixa a DAC no cold-boot default e
aplica volume só na camada de software… que por sua vez não é aplicada no hardware
analógico por falta do init do mixer.

**Correção: forçar as DACs analógicas à escala cheia via UCM**, que o HAL executa a cada
ativação de verb/device (comprovado que o `cset` do UCM chega ao hardware — os switches dos
mesmos arquivos sempre foram aplicados com sucesso):

```
# /vendor/etc/alsa/ucm2/Intel/sof-hda-dsp/HiFi.conf (SectionVerb EnableSequence)
cset "name='Master Playback Volume' 100%"
cset "name='Speaker Playback Volume' 100%"
cset "name='Headphone Playback Volume' 80%"
```

mais os mesmos `cset` nos EnableSequence dos devices em `HDA/HiFi-spk.conf` (Speaker) e
`HDA/HiFi-analog.conf` (Headphones), como reforço.

## Como aplicar

Script pronto e idempotente:

```sh
sudo /home/iris/android17/patch_vendor_ucm_volume.sh /caminho/da/android-dir/vendor.img
# sem argumento: usa /mnt/p7/android-Generic_x86_64/vendor.img
```

O patch (ferramentas em `extracted/erofs-inst/bin`):

1. extrai o `vendor.img` EROFS preservando dono/permissões/xattrs SELinux;
2. edita os 3 arquivos UCM inserindo os `cset` de volume (marcados com
   `NO-SOUND FIX (2026-11-08)`, removidos/reinseridos em re-execução → idempotente);
3. **preserva o `build.prop` do fix do bootloop** (valida
   `ro.surface_flinger.enable_frame_rate_override=true` na linha 62 e
   `ro.boot.hwc_apex=2` na 161 antes de trocar a imagem);
4. reempacota com `mkfs.erofs -zlz4 --mount-point=/vendor --preserve-mtime -T <ts original>`;
5. monta em loop e valida os `cset` antes de trocar o arquivo (backup `.before_ucm`).

## Verificação

Boot normal; no Terminal do Android (sem su):

```sh
# 1) log mostra o HAL ativando o verb HiFi do card 0:
logcat -d | grep MainlineAudio_Ucm          # "Open: hw:0 ... _boot done"

# 2) codec dump — as DACs devem ter subido de 0x11 para:
cat /proc/asound/card0/codec#0 | grep -A3 "Node 0x02 \["   # Amp-Out vals [0x57 0x57]
cat /proc/asound/card0/codec#0 | grep -A3 "Node 0x03 \["   # Amp-Out vals [0x57 0x57]
```

**Resultado medido no hardware:** som de caixa e fone funcionando perfeitamente
(confirmação do usuário, 2026-11-08). O volume do framework (FN+F7/F8) continua
funcionando por cima (volume de software, curva de índice → dB do APM).

## Cadeia de evidência (resumo)

| Passo | Evidência | Conclusão |
|---|---|---|
| Som no USB funciona | teste do usuário | stack de roteamento/PCM OK; falha restrita ao caminho analógico (ALC256) |
| PCM roda, `xruns=0` | `hw_params_loop.txt`, `som.log`/`som2.log` | sinal chega ao SOF |
| Codec dump Android vs host | `proc_asound_card0.txt` vs `/proc/asound/card0/codec#0` (CachyOS) | DAC 0x02/0x03: `0x11` vs `0x57`/`0x34` |
| HAL aplica "100%" só no USB | `som2.log:37794` `InitializeMixer: card 1 playback=100%` | card 0 **nunca** recebe `InitializeMixer` em nenhum boot |
| Framework nunca escreve a DAC | `Dac_loop.txt` (30 s, 0,5 s/captura) | 0x11 constante: volume max/min, plug/unplug, playback |
| Curva de volume APM correta | `audio_policy_engine_*_volumes.xml` (índice 100 → 0 mB) | falha não é da curva |
| Binário HAL usa `mixer_ctl_set_percent` (tinyalsa) + `snd_mixer_selem_*` (alsa-lib, `InitializeMixer`) | disassembly do `android.hardware.audio.service-aidl.mainline` | caminhos separados; card 0 sem init |
| UCM `cset` chega no hardware | switches dos mesmos arquivos sempre aplicados | correção via UCM é viável |
| **Fix UCM aplicado → som 100%** | confirmação do usuário | **correção validada** |

## Recomendações para o upstream (projeto)

1. **Inicializar o mixer do card primário no boot** — o `MainlineAudio` HAL deveria rodar
   o `InitializeMixer` (ou equivalente tinyalsa 100%/80%) também para o card primário no
   startup, e não apenas para cards que aparecem depois.
2. Alternativa robusta: embutir os `cset` do SectionVerb (como neste patch) na
   configuração `Intel/sof-hda-dsp` do device tree, que cobre todos os SoC Intel HDA.
3. Talvez expor propriedade (`mixer.init_always=1`) no HAL para forçar init em todos cards.

## Rollback

`vendor.img.before_ucm` (estado pré-fix-de-som) fica do lado do `vendor.img`:

```sh
sudo cp vendor.img.before_ucm vendor.img
```

Para voltar ao estado totalmente original (antes de AMBOS os fixes):
`sudo cp vendor.img.orig vendor.img` — mas isso também reverte o fix do bootloop.

## Notas de manutenção

- **Re-executar o patch após reinstalação/OTA** (o `vendor.img` é substituído).
- Executar primeiro `patch_vendor_hwc.sh` e depois `patch_vendor_ucm_volume.sh`
  (ou vice-versa): ambos preservam as edições do outro — o script de UCM valida o
  `build.prop` antes de trocar.
- Se o upstream reestruturar os arquivos UCM (`Intel/sof-hda-dsp/HiFi.conf`,
  `HDA/HiFi-spk.conf`, `HDA/HiFi-analog.conf`), os âncoras do script precisam de ajuste.
- O patch mexe **somente no volume analógico em hardware** (DAC amps); o volume de
  software (framework) continua aplicado por cima — a curva de índice → dB do APM
  continua fazendo a atenuação sobre a escala cheia do hardware.
