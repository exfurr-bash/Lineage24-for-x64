# Draft comment for IzumiSenaSora/Generic_X86_64#3

(Post as regular user `iris`. This replaces the earlier draft that blamed
`drm_hwcomposer_upstream` — that theory was disproved: forced drmfb crashes identically.
Full analysis in `issue3-root-cause.md`.)

---

## Found it: it's not the composer — the device tree disables frame rate override, and real panels report fractional refresh rates (~60.003 Hz), which kills SurfaceFlinger

**TL;DR**

```
ro.surface_flinger.enable_frame_rate_override=false    # /vendor/build.prop, from
                                                       # configs/properties/vendor.prop:21
```

Combined with an internal panel whose mode is **60.003117 Hz** instead of exactly 60,
SurfaceFlinger aborts (`SIGABRT`) with

```
No matching frame rate modes for primary range even after ignoring the render range.
policy: {defaultModeId=0, allowGroupSwitching=false, primaryRanges={physical=[0.00 Hz, inf Hz],
render=[0.00 Hz, 60.00 Hz]}, appRequestRanges={physical=[0.00 Hz, inf Hz], render=[0.00 Hz, inf Hz]}}
```

**Verified fix — boot completes to a fully functional UI** (tested on i5-1335U / Iris Xe
`8086:a7a1`, eDP 1080p panel, build `lineage-24.0-20261020-UNOFFICIAL-0xCAFEBABE`):

```
ro.surface_flinger.enable_frame_rate_override=true     # in /vendor/build.prop
```

### Details

1. `configs/properties/vendor.prop` line 21 ships
   `ro.surface_flinger.enable_frame_rate_override=false` on every Generic x86_64 build.
2. With override disabled, **DisplayManagerService** validates the display mode against its
   primary **render** range using the Java tolerance `FLOAT_TOLERANCE = 0.01f`
   (`VoteSummary.validateModeWithinRenderRefreshRange`), so the 60.003117 Hz mode *passes*
   and the specs `[0–∞, 0–60.0]` (render max from the framework default peak refresh rate =
   60) are handed to SurfaceFlinger.
3. **SurfaceFlinger** re-validates with the C++ `Fps` epsilon of **0.001 Hz**
   (`scheduler/Fps.h`, `isApproxEqual`). `60.003117 − 60.000000 = 0.003117 > 0.001` → the
   only mode of the panel is rejected → zero frame-rate modes → `LOG_ALWAYS_FATAL`.
4. The "even after ignoring the render range" retry can't save it while override is
   disabled: the retry reuses the same `filterModes` lambda, which still consults the
   captured `ranges.render` — so "ignoring" is a lie in this configuration (adjacent to
   upstream TODO b/292105422). One benign centi-hertz rounding artifact ⇒ hard bootloop.
5. Composer is irrelevant — I forced both `drm_hwcomposer_upstream` (default) and `drmfb`
   (`ro.boot.hwc_apex=2`, override honored by `hardware_detect`/apexd in the live log) and
   they crash identically. GPU rendering itself is healthy (mesa/Vulkan fine).
6. This is why VMs and `nomodeset` appear to work: those paths hand SF modes that are
   integer-rates integer (60.000000), which fit through the 0.001 Hz epsilon. Real laptop
   eDP panels (i915-computed from panel timings) are frequently 60.003-style.

### Suggested fix for the device tree

- Preferred: remove the `ro.surface_flinger.enable_frame_rate_override=false` block from
  `configs/properties/vendor.prop` (upstream AOSP defaults to enabled on both the Java
  `.orElse(true)` and the C++ caller-default side, so the explicit `false` is the delta).
- If the line exists for a reason, a fallback that doesn't bootloop real panels would help:
  either accept fractional panel rates (clamp render max to the active mode's fps) or stop
  `LOG_ALWAYS_FATAL_IF`'ing when the ignored-render-retry comes back empty.

Happy to provide full logs (`logcat`, tombstones) and the exact patch sequence — the whole
root-cause write-up with line references is ready.

---
