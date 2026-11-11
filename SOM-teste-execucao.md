# Teste de som no LineageOS (p7) — checklist de coleta

Contexto: stack de áudio de boot está 100% saudável (kernel SOF OK, HAL mainline OK,
AudioFlinger/APM roteando AUDIO_DEVICE_OUT_SPEAKER no card 0 `sofhdadsp`).
P7: /dev/nvme0n1p7, /data → userdata/.
Volume OK (25/25, não mutado), jack de fone corretamente "unplugged".
PCM do hardware abriu e rodou: TryOpen _ucm0001.hw:sofhdadsp, position avança, xruns=0
→ sinal chega ao SOF. Suspeita: amp/mute do codec (ALC256, pin 0x14) em runtime.

## 1. Bota no Android (Boot0003 "LineageOS 24.0 dbg"; já é o 1º da BootOrder)

## 2. Terminal, sem su, rodada 1 (estado inicial):
```
logcat -d > /data/local/tmp/som.log
dumpsys audio > /data/local/tmp/ds_audio.txt
dumpsys media.audio_flinger > /data/local/tmp/ds_flinger.txt
```

## 3. Teste sonoro (janela aberta)
- Volume + / Volume − ~5x cada
- **Conecta fone P2 ~10 s enquanto toca um som**, depois desconecta
- Se tiver app/navegador que toque vídeo/música: toca ~10 s

## 4. Rodada 2 (runtime, no Terminal, sem su):
Loop do hw_params (prova se o PCM estava RUNNING na hora do som):
```
( while [ ! -f /data/local/tmp/STOP ]; do cat /proc/asound/card0/pcm0p/sub0/hw_params 2>/dev/null; sleep 0.2; done ) > /data/local/tmp/hw_params_loop.txt
```
deixe rodando, aperte volume + − algumas vezes; se tiver tocando algo, deixe tocar
uns segundos; depois:
```
touch /data/local/tmp/STOP
```
Dump do codec + log:
```
ls /proc/asound/card0/ > /data/local/tmp/proc_asound_card0.txt
cat /proc/asound/card0/codec#* >> /data/local/tmp/proc_asound_card0.txt
cat /proc/asound/cards >> /data/local/tmp/proc_asound_card0.txt
logcat -d > /data/local/tmp/som2.log
```

## 5. Volta pro CachyOS e chama o agente para analisar. Arquivos em:
/mnt/p7/android-Generic_x86_64/userdata/local/tmp/

O que comparar contra a referência do HOST (CachyOS, ALC256, som FUNCIONA):
- /proc/asound/card0/codec#0 → Node 0x14 (speaker):
  - Amp-Out vals: [0x00 0x00] (não mutado)
  - Pin-ctls: 0x40 (OUT)
  - Power: setting=D0, actual=D0
- hw_params_loop.txt: em algum momento deve aparecer format/channels/rate
  (prova de stream aberto na hora do som)
- som2.log: rota no momento do teste

Resultados anotados (2026-11-08, todos concluídos):
- Rodada 1 coletada (som.log, ds_audio.txt, ds_flinger.txt) ✓
- Fone P2: mute (analógico só); **fone USB-A: som funciona** ✓ (dado-chave do diagnóstico)
- Rodada 2 runtime: hw_params_loop.txt (tudo "closed" no momento), proc_asound_card0.txt,
  som2.log ✓ — **causa raiz achada: DACs ALC256 (nodes 0x02/0x03) em `0x11` (−52,5 dB) vs
  host `0x57`; HAL só roda InitializeMixer no card USB (card 1), nunca no card 0 analógico**
- Rodada 3 runtime (Dac_loop.txt, som3.log) ✓ — DAC travada em 0x11 durante volume
  max/min (FN+F7/F8), plug/unplug de fone e playback: **Android nunca escreve no mixer
  analógico**
- **CORREÇÃO aplicada**: `patch_vendor_ucm_volume.sh` → `/vendor/etc/alsa/ucm2`
  (HiFi.conf SectionVerb + HDA/HiFi-spk.conf + HDA/HiFi-analog.conf) forçando
  Master/Speaker 100% e Headphone 80% ✓
- **VERIFICADO PELO USUÁRIO**: "audio funcionando perfeitamente!" ✓
- Documentação completa: `/home/iris/android17/SOM-fix-guide.md`
