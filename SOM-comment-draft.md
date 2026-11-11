# Draft issue/comment — no sound on analog outputs (ALC256) with MainlineAudio HAL

(For the Generic_X86_64 repo, potentially a new issue since it's independent of
#3. Posting as user `iris`. Full local analysis: `SOM-fix-guide.md`.)

---

## No sound on internal speaker / analog headphone jack (ALC256) — analog card mixer is never initialized; USB audio works

**Hardware:** Samsung Galaxy Book NP750XGJ, i5-1335U (RPL-U, audio `8086:51CA`),
code Realtek ALC256, SOF `skl_hda_dsp_generic`, card 0 `sofhdadsp`.
**Build:** `lineage-24.0-20261020-UNOFFICIAL-0xCAFEBABE` (Generic x86_64, mainline kernel).

**TL;DR**

- USB headphones (bypassing the codec) work → the whole routing/PCM stack is healthy.
- The ALC256 *cold-boot* default for both playback DAC amps (nodes 0x02 speaker /
  0x03 headphone) is `Amp-Out vals [0x11 0x11]` → 17/87 steps × 0.75 dB = **−52.5 dB**,
  i.e. inaudible.
- Linux distros work because `alsactl restore` sets the DAC to 100% at boot. Android
  mainline audio (HAL `MainlineAudio`, APEX `com.android.hardware.audio.mainline`)
  doesn't run alsactl — and the HAL only runs `InitializeMixer` (alsa-lib, 100%) for
  **cards that appear after startup** (USB hot-plug: `InitializeMixer: card 1
  playback=100%`). The analog card 0, present at boot, **never** gets it.
- Proven at runtime with a 0.5 s capture loop on `/proc/asound/card0/codec#0`:
  the DAC stayed at `[0x11 0x11]` the whole time while pressing volume keys to max,
  plugging/unplugging the jack and playing audio. **Android never writes the analog
  mixer.** Framework volume (index 25/25, curve ending at 0 mB) is fine — it's just
  software-side.

**Log evidence**

```
I MainlineAudio_AlsaMixer: InitializeMixer: card 1 playback=100% capture=80% ...   # USB only
I MainlineAudio_Ucm: Open: hw:0 profile "sof-hda-dsp.conf" verb "HiFi" with 7 device(s)
# codec#0 (Android):      Node 0x02 / 0x03: Amp-Out caps ofs=0x57 nsteps=0x57 stepsize=0x02,
#                                                Amp-Out vals: [0x11 0x11]   ← −52.5 dB
# codec#0 (CachyOS host):  Node 0x02:           Amp-Out vals: [0x57 0x57]   ← 0.0 dB
```

**Verified fix (speaker + headphones working)** — force the DACs via UCM, which the
HAL applies on every verb/device activation (we know UCM csets reach the hardware
because the *Switch* csets in those same files were always applied):

```text
etc/alsa/ucm2/Intel/sof-hda-dsp/HiFi.conf — SectionVerb EnableSequence:
    cset "name='Master Playback Volume' 100%"
    cset "name='Speaker Playback Volume' 100%"
    cset "name='Headphone Playback Volume' 80%"

etc/alsa/ucm2/HDA/HiFi-spk.conf — Speaker EnableSequence:
    cset "name='Speaker Playback Volume' 100%"   (before the Switch cset)

etc/alsa/ucm2/HDA/HiFi-analog.conf — Headphones EnableSequence:
    cset "name='Headphone Playback Volume' 80%"  (before the Switch cset)
```

This also confirms the *SOF-side* was never the problem: the intercept is purely the
uninitialized codec amps. The proper upstream fixes, in order of preference:

1. `MainlineAudio` HAL: run `InitializeMixer` for the primary card at startup too
   (currently only for late-appearing cards).
2. Device tree: ship the DAC-level `cset`s in the `sof-hda-dsp` UCM profile (as above) —
   covers all Intel HDA platforms.
3. The HAL binary has both a tinyalsa path (`mixer_ctl_set_percent`) and an alsa-lib
   path (`snd_mixer_selem_*`) — the two diverge in what they initialize.

(**Apêndice PT-BR:** documentação local completa em `SOM-fix-guide.md`; patch
reprodutível em `patch_vendor_ucm_volume.sh`, idempotente, com verificação do `build.prop`
do fix do issue #3 antes de trocar a imagem. Backups: `vendor.img.before_ucm`,
`vendor.img.orig`.)
