# Root cause of the LineageOS 24.0 Generic x86_64 bootloop on Intel RPL-U — issue #3 (IzumiSenaSora/Generic_X86_64)

**Status: root cause CONFIRMED by code analysis + live logs + successful boot test.**
All earlier hypotheses that the composer APEX (`drm_hwcomposer_upstream` vs `drmfb`) was
the culprit are **wrong**; they were falsified empirically on 2026-11-08 (both composers
crash identically) and superseded by the analysis below.

| | |
|---|---|
| ISO | `lineage-24.0-20261020-UNOFFICIAL-0xCAFEBABE-Generic_x86_64` |
| Hardware | Lenovo laptop, i5-1335U; iGPU `8086:a7a1` Iris Xe (i915), internal eDP panel 1920×1080@60 |
| Crash | `SIGABRT` in `surfaceflinger`, `LOG_ALWAYS_FATAL_IF` in `RefreshRateSelector::constructAvailableRefreshRates` |
| Fix (verified) | `ro.surface_flinger.enable_frame_rate_override=true` in `/vendor/build.prop` |
| Composer state at crash time | irrelevant (tested with `drm_hwcomposer_upstream` *and* `drmfb`) |

---

## 1. Symptom

With the stock vendor image the system bootloops at the bootanimation:

```
surfaceflinger: F/ (main): No matching frame rate modes for primary range even after ignoring
the render range. policy: {defaultModeId=0, allowGroupSwitching=false, primaryRanges=
{physical=[0.00 Hz, inf Hz], render=[0.00 Hz, 60.00 Hz]},
appRequestRanges={physical=[0.00 Hz, inf Hz], render=[0.00 Hz, inf Hz]}}
→ Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) ... surfaceflinger
```

30+ identical aborts in a row (i.e., every ~2.5 s after SystemServer phase 520). The panel
**has** exactly one display mode, and it is 60.003117 Hz. The DMS→SF handoff still ends
with an empty mode set inside SF. Full first-boot log: `diag1/early_logcat.log` (46 k lines;
fatal chain at lines 15581–15820, DisplayDeviceInfo dump at line 7968).

Key log excerpt (`Lineage 24.0`, one boot cycle):

```
05:35:21.436 DisplayDeviceRepository: Display device added: DisplayDeviceInfo{"Built-in Screen":
  uniqueId="local:4624213903473446400", 1920 x 1080, modeId 1, renderFrameRate 60.003117,
  hasArrSupport false, frameRateCategoryRate FrameRateCategoryRate {normal=60.0, high=90.0},
  supportedRefreshRates [60.003117], defaultModeId 1, userPreferredModeId -1,
  supportedModes [{id=1, parentModeId=-1, sfModeId=0, flags=, width=1920, height=1080,
  fps=60.003117, vsync=60.003117, alternativeRefreshRates=[]}], ...}
```

## 2. The complete causal chain

### 2.1 The device tree disables frame rate override

`android_device_mainline_generic/configs/properties/vendor.prop`, line 21:

```
# Display
ro.surface_flinger.enable_frame_rate_override=false
```

This lands in `/vendor/build.prop` (installed image: line 62). Two consumers read the same
`ro.surface_flinger.enable_frame_rate_override` property:

- **frameworks/base side** (`DisplayModeDirector`), line 3390:
  ```java
  public boolean supportsFrameRateOverride() {
      return SurfaceFlingerProperties.enable_frame_rate_override().orElse(true);
  }
  ```
- **frameworks/native side** (`SurfaceFlinger::onHotplugConnect*` → `RefreshRateSelector::Config`),
  SurfaceFlinger.cpp ~line 4282:
  ```cpp
  const Config config = {.enableFrameRateOverride =
                              sysprop::enable_frame_rate_override(true) || isVrrConfigured, ...};
  ```

Note what happens for each value:

| prop value | DMS `mSupportsFrameRateOverride` | SF `config.enableFrameRateOverride` |
|---|---|---|
| unset | `true` (`.orElse(true)`) | `true` (caller default `true`) |
| `false` | `false` | `false` |
| `true` | `true` | `true` |

Both sides agree in every case. The failure mode is only reachable when the prop is
**explicitly `false`** — which is what this device tree ships for every Generic x86_64 build.

### 2.2 The panel reports a non-integer refresh rate

The internal eDP panel's mode computed by i915/KMS is **60.003117 Hz**, not exactly 60
(see the `DisplayDeviceInfo` dump above; `fps=60.003117, vsync=60.003117`, the only mode).
This is a ~0.3-centi-hertz artifact of the panel's pixel-clock/timing arithmetic — typical
for real laptop eDP panels (this is why `nomodeset`/`simpledrm` "works": those paths happen
to present different mode data to SF, but the crash below needs `ro.surface_flinger…
enable_frame_rate_override=false` **plus** a fractional panel rate, so `nomodeset`
masks it only incidentally).

### 2.3 DMS keeps the mode (Java tolerance 0.01 Hz) and sends `render=[0, 60.0]`

At first boot, user settings are empty, so the `SettingsObserver` votes come from the
framework default `config_defaultPeakRefreshRate` / `config_defaultRefreshRate` = **60.0f**
(fresh GSI; no persisted `PEAK_REFRESH_RATE` yet, userdata starts empty):

```java
// DisplayModeDirector$SettingsObserver.updateRefreshRateSettingLocked
Vote peakRenderVote = Vote.forRenderFrameRates(0f, Math.max(minRefreshRate, peakRefreshRate)); // [0, 60.0]
Vote defaultVote    = defaultRefreshRate == 0f ? null
                     : Vote.forRenderFrameRates(0f, defaultRefreshRate);                        // [0, 60.0]
```

Because `DMS.supportsFrameRateOverride == false`, DMS's own `VoteSummary.filterModes`
applies the render-range validation with the **Java** tolerance
(`SurfaceControl$RefreshRateRange.FLOAT_TOLERANCE = 0.01f`):

```java
// VoteSummary.validateModeWithinRenderRefreshRange — runs when frame rate override is disabled
if (refreshRate < (minRenderFrameRate - FLOAT_TOLERANCE)      // 60.003117 < 0 - 0.01?  no
        || refreshRate > (maxRenderFrameRate + FLOAT_TOLERANCE)) {  // 60.003117 > 60.0 + 0.01?  no!
    ... // discarded
}
```

`60.003117 ≤ 60.0 + 0.01` → the mode **survives**. So DisplayModeDirector finds a non-empty
allowed-mode set on its first pass and faithfully reports the vote range to SF:

```
primary { physical = [0.0, ∞], render = [0.0, 60.0] }
```

(The printed `60.00 Hz` in the fatal message is `to_string(Fps)` = `%.2f`; the true value
in these votes is the float `60.0f`.)

### 2.4 SurfaceFlinger rejects it (C++ epsilon 0.001 Hz)

SF-side, with `enableFrameRateOverride == false`, the primary range filter
in `RefreshRateSelector::constructAvailableRefreshRates()` (RefreshRateSelector.cpp,
lines ~1624–1636) hard-requires the mode's peak fps to be inside the render range using
the **C++** `Fps` approximate comparison, whose epsilon is **0.001 Hz**
(`Scheduler/include/scheduler/Fps.h`):

```cpp
inline bool isApproxEqual(Fps lhs, Fps rhs) {
    return std::abs(lhs.getValue() - rhs.getValue()) < 0.001f;   // vs Java's 0.01f!
}

inline bool FpsRange::includes(Fps fps) const {
    using fps_approx_ops::operator<=;
    return min <= fps && fps <= max;
}
```

Numbers:

```
mode peak fps          = 60.003117
render range max       = 60.000000   (config_defaultPeakRefreshRate-derived vote)
difference             = 0.003117
Java tolerance (DMS)   = 0.01    → 0.003117 < 0.01    → mode ACCEPTED by DMS
C++  epsilon  (SF)     = 0.001   → 0.003117 > 0.001   → 60.0 < 60.003117  → mode REJECTED by SF
```

The display has **one** mode. One rejected mode ⇒ zero matches:

```cpp
// RefreshRateSelector.cpp:1638
auto frameRateModes = createFrameRateModes(*policy, filterModes, ranges.render, ...);
if (frameRateModes.empty()) {
    ALOGW("No matching frame rate modes for %s range. policy: %s", rangeName, ...);
    // TODO(b/292105422): Ideally DisplayManager should not send render ranges
    //  smaller than the min supported. ... For not we just ignore the render ranges.
    frameRateModes = createFrameRateModes(*policy, filterModes, {}, ...);   // "ignore render range"
}
LOG_ALWAYS_FATAL_IF(frameRateModes.empty(),
                    "No matching frame rate modes for %s range even after ignoring the "
                    "render range. policy: %s", rangeName, policy->toString().c_str());
```

### 2.5 The "ignore the render range" retry cannot help — and the message lies

The retry *does not* ignore the render range in this configuration. The inner
`filterModes` lambda **captures the outer `ranges` parameter by reference**; only the
third argument of `createFrameRateModes` (used for divisor selection) becomes empty.
The render-range constraint inside `filterModes`…

```cpp
(supportsFrameRateOverride() || ranges.render.includes(mode.getPeakFps()))
```

…is skipped **only** when frame rate override is enabled. With the prop `false`, the
constraint is inverted to a hard requirement, the same single mode is filtered out again,
the retry returns an empty set too, and `LOG_ALWAYS_FATAL_IF` fires — SIGABRT.
(When `enableFrameRateOverride == true`, the retry actually works, which is why the same
code path is harmless on builds that leave the prop unset.)

Observation: the empty render-range-lambda capture makes the misleading error message a
second (upstream) bug in the same function, adjacent to upstream TODO b/292105422.

### 2.6 Cycle

SF aborts → init restarts it (`init_fatal_reboot_target=recovery` etc.), SystemServer /
boot remains incomplete → perceived bootloop at the bootanimation, 30+ identical
tombstones (recorded in `diag1/tombstones/`).

## 3. Why both composer APEXes crash identically (the disproved hypothesis)

The first theory attributed the crash to `drm_hwcomposer_upstream`. This was tested by
patching `vendor/build.prop` with `ro.boot.hwc_apex=2`
(`hardware_detect: ProcessBootOverrides(): Override hwc_apex from 1 to 2` confirmed in the
live log at 05:35:14.201; apexd honored it: `Set HWComposer APEX to
com.android.hardware.graphics.composer.drmfb`). The bootloop persisted **identically**:
same fatal, same policy print. Conclusion: the failing layer is not the composer at all —
it is the DMS→SF policy interplay described in §2, which is composer-agnostic. This is
corroborated by the fact that the default Intel path (`Drm`) and the fb mirror composer
(`DrmFb`) are independent processes; only the `DisplayMode` fps they surface (from KMS
modes, identical in both cases) enters the equation.

## 4. Why most other x86_64 hardware does not hit this

The crash needs the exact conjunction:

1. `ro.surface_flinger.enable_frame_rate_override=false` — every Generic x86_64 24.0 build.
2. A display mode whose fps is non-integer in a way that falls into the
   (0.001 Hz, 0.01 Hz] band above a round number — real eDP/DP panels; Intel i915 uses the
   panel's own timings, so ~60.003 Hz is common.
3. DMS votes that clamp the render range at exactly the rounded value (60.0 from the
   framework defaults; any machine where peak refresh config is higher does not clamp at 60).

VMs/QEMU, `simpledrm`/`vesadrm` fallbacks and most external monitors expose integer rates
(59.940 suppressed/normalized, exactly 60.000000) → `includes()` passes → no crash.
Real laptop panels that report 60.003-style rates with this device tree → crash. Note
DisplayModeDirector even contains a comment showing awareness of the external-display
variant ("Some external displays physical refresh rate modes are slightly above 60hz. …
SurfaceFlinger will not enable these display modes unless it is configured to allow render
rate at least at this frame rate.") — but that bump (`Math.max(baseMode.getRefreshRate(),
primarySummary.maxRenderFrameRate)`) is applied **only for external displays**
(`isExternalDisplayLocked`), never for the internal panel, which happens to be exactly the
case that bit this laptop.

## 5. Verified fix

Flip the prop to `true` (which merely restores the AOSP default — both SF and DMS default
to enabled when the prop is unset):

```
/vendor/build.prop:  ro.surface_flinger.enable_frame_rate_override=true
```

Mechanism once enabled:

- `filterModes` skips the render-range requirement;
- `createFrameRateModes` computes framework-rate divisors of the active mode's vsync rate
  (60.003117/1 → excluded by the (separately existing) `renderRange.includes()` divisors
  check; 60.003117/2 ≈ 30.0016; /3 ≈ 20.001 → included), so the primary frame-rate list is
  non-empty, no fatal, and boot proceeds with content-driven rate selection afterwards.

**Boot test result (2026-11-08): boots to a fully functional UI, no bootloop; shipped with
the Linux Terminal app installed and usable.** The patched vendor.img on the test install
(`/dev/nvme0n1p7`, UUID `06a5aae3-b1aa-4944-a4e2-1f98200ef1d8`) contains both

```
ro.surface_flinger.enable_frame_rate_override=true   # the fix (was `false`)
ro.boot.hwc_apex=2                                   # leftover from the earlier experiment
```

The `hwc_apex=2` line is almost certainly unnecessary for the fix (composer choice is
irrelevant, see §3) but was **not** separately A/B-tested; keep it if you copy the image
one-to-one, or A/B-test it yourself by removing just that line.

## 6. Recommendations

1. **Project device tree** (`android_device_mainline_generic`): delete
   `ro.surface_flinger.enable_frame_rate_override=false` from `configs/properties/vendor.prop`
   (the default `true` matches upstream AOSP behavior for builds; if the line exists for a
   real reason, document it — today it only bootloops real panels with fractional rates).
2. **AOSP-side hardening** (bugs to file/reference upstream):
   - The "ignore render range" retry cannot do anything when `enableFrameRateOverride == false`
     because `filterModes` still consults the captured `ranges` (lambda capture bug adjacent
     to TODO b/292105422); its `LOG_ALWAYS_FATAL_IF` then turns a benign rounding artifact
     into a hard bootloop.
   - Tolerance mismatch across the DMS/SF boundary: Java `FLOAT_TOLERANCE = 0.01f`
     (android.view.SurfaceControl) vs C++ `isApproxEqual` epsilon `0.001f`
     (scheduler/Fps.h). DMS validates what SF then rejects. Either align the epsilons or
     have SF clamp the render max up to the active mode's fps when out of range, instead of
     the current fatal.
   - Consider applying the external-display `maxRenderFrameRate` bump to internal panels
     whose mode fps exceeds the policy render max by a fractional amount.
3. **`nomodeset` help is incidental**: it replaces the i915-computed fractional mode with a
   system-framebuffer mode, changing the failing input — it does not address the real bug.

## 7. Evidence index

| Evidence | Where |
|---|---|
| Full early-boot log of a failing cycle ×5 | `diag1/early_logcat.log` (fatal chain lines 15581–15820) |
| `DisplayDeviceInfo` dump (mode fps 60.003117) | `diag1/early_logcat.log` line 7968 |
| Tombstones / dropbox of failing cycles | `diag1/tombstones/`, `diag1/dropbox/` |
| `hardware_detect` override experiment (hwc_apex 1→2 honored, same crash) | same log, 05:35:14.201 |
| Device tree prop | `extracted/android_device_mainline_generic/configs/properties/vendor.prop` line 21 |
| Installed vendor.img evidence of both lines | `/vendor/build.prop` lines 62 and 161 (in `nvme0n1p7` android-dir `vendor.img`) |
| SF constexpr + retry + fatal | `frameworks_native/services/surfaceflinger/Scheduler/RefreshRateSelector.cpp` ~L1606–1655, L208–228, L293–315 |
| Epsilon | `frameworks_native/services/surfaceflinger/Scheduler/include/scheduler/Fps.h` |
| Prop read (SF) | `frameworks_native/services/surfaceflinger/SurfaceFlinger.cpp` ~L4282 |
| Prop read (DMS) | `frameworks_base/services/core/java/com/android/server/display/mode/DisplayModeDirector.java` L3390, injector `RealInjector.supportsFrameRateOverride` |
| Java tolerance | `frameworks_base/core/java/android/view/SurfaceControl.java` L2334 |
| DMS vote sources | same file, `SettingsObserver.updateRefreshRateSettingLocked` (~L1267–1318) |
| Successful boot test after fix | on-device, 2026-11-08, UI functional |

## 8. Reproduce the analysis locally

```sh
L=diag1/early_logcat.log
grep -n "No matching frame rate modes" $L            # SF fatal
grep -n "DisplayDeviceRepository: Display device added" $L | head -3   # fps dump
grep -n "hardware_detect" $L | grep -iE "hwc_apex|APEX|override"
# device tree side:
grep -n "enable_frame_rate_override" extracted/android_device_mainline_generic/configs/properties/vendor.prop
```

Patch script used on the install (idempotent, keeps original as `.orig`):
`/home/iris/android17/patch_vendor_hwc.sh`, together with erofs tools at
`extracted/erofs-inst/bin` (ERFS extract → build.prop sed → `mkfs.erofs -zlz4
--mount-point=/vendor --preserve-mtime -T <orig build time>` → verify by loop mount).
