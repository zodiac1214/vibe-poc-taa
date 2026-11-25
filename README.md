# vibe-poc-taa

> [!WARNING]
> **Unsupported and against LR's recommendation. Use at your own risk.**
>
> LR recommends that we **do not tap into our rendering engine**. This project
> does exactly that, so it goes **against that recommendation**.
>
> - This is a **vibe-coded proof of concept** made **for study only**.
> - It is **not production code**. Nobody has reviewed it, hardened it, or
>   checked it for performance, correctness, or security.
> - It **will not be maintained**. Expect no fixes, updates, or support.
>   Issues and pull requests may be ignored.
> - Do not depend on it, ship it, or copy it into supported code.
> - Injecting into third-party apps may break DRM, launchers, anti-cheat or
>   online play, and may violate their terms of service.
>
> If you use any part of this repository, the consequences are yours.

## What it is

A macOS dylib that adds a **TAA-style temporal filter** and **MetalFX upscaling
(e.g. to 4K)** to a Metal app by **intercepting the Metal API at runtime**.
The target binary is never patched. The dylib is loaded with
`DYLD_INSERT_LIBRARIES` and swizzles a few Objective-C methods:

| Hook | What it does |
| --- | --- |
| `-[CAMetalLayer setDrawableSize:]` / `-drawableSize` | Remembers the size the game asked for and reports it back unchanged, while the *real* drawable is resized to the output size. |
| `-[CAMetalLayer nextDrawable]` | Returns a proxy drawable whose `.texture` is an offscreen target at the game's size. |
| `-[MTLCommandBuffer presentDrawable:]` (+ `atTime:` / `afterMinimumDuration:`) | When handed a proxy, appends: TAA-lite pass → MetalFX spatial upscale → copy into the real drawable, then presents the real drawable. |

```
game renders ──► offscreen (game res) ──► TAA-lite (history, RGBA16F)
                                             │
                                             ▼
                real CAMetalLayer drawable ◄── MetalFX spatial scaler (native / 4K)
```

The idea: set the game to a lower resolution in its own settings (e.g. 1080p)
and the injector reconstructs native or 4K output at the end of the frame.

## Honest limitations

- **It's TAA-lite, not real TAA.** Real TAA (and the MetalFX *temporal* scaler)
  needs per-frame **projection jitter, motion vectors and depth**. Those live
  inside the engine and you can't recover them generically from outside it.
  What's here is temporal accumulation with YCoCg variance clipping. It reduces
  shimmer and flicker but adds no sub-pixel detail, and fast motion falls back
  to the current frame. Wiring in the temporal scaler would mean per-game
  hooks that find the engine's depth and motion textures and its jitter. That's
  out of scope.
- **UI is upscaled too.** The whole final frame is processed, HUD included.
- **Direct `[drawable present]`** (X-Plane does this) is submitted on the queue
  the game rendered with, which the render-encoder hook records, so GPU order
  is kept. With several frames in flight the upscaled image can be one frame
  newer than the drawable it lands on. If no game queue is known, it falls
  back to the last queue anything was committed on, then to the injector's own
  queue.
- **Hardened runtime.** Most shipped apps ignore `DYLD_INSERT_LIBRARIES` or
  reject ad-hoc signed dylibs. `scripts/resign-copy.sh` ad-hoc re-signs a
  **copy** with the needed entitlements, which carries all the risks in the
  warning above. SIP-protected and platform binaries can't be injected at all.
- Only `CAMetalLayer`-based presentation is covered (which includes MTKView and
  MoltenVK). Tested only with the bundled test app on Apple Silicon (M2 Max,
  macOS 26), native and under Rosetta. **Not tested against any real game.**

## Build

Requires Xcode command line tools and macOS 13+ (MetalFX). Builds a universal
(arm64 + x86_64) dylib, so Rosetta games work too.

```sh
make          # build/libtaa_inject.dylib + build/taa_testapp
make demo     # test app at 960x540 → native, dumps build/demo_{input,output}.png
```

## Use

```sh
# Test app (a fan of thin wedges, worst-case aliasing)
TAA_LOG=1 scripts/taa-launch.sh build/taa_testapp

# An app (checks hardened runtime and warns if injection will be blocked)
TAA_OUTPUT=4k scripts/taa-launch.sh /Applications/Some.app

# If blocked: re-sign a copy (original untouched), then launch the copy
scripts/resign-copy.sh /Applications/Some.app ~/taa-apps/Some.app
TAA_OUTPUT=4k scripts/taa-launch.sh ~/taa-apps/Some.app
```

### X-Plane 12 on an ultrawide (5120×1440)

Tested only at the main menu with X-Plane 12.4.4-r2 on an M2 Max. X-Plane is
built with `get-task-allow`, so it can be injected **without re-signing**.
X-Plane renders the full scene at the reduced size and MetalFX brings it back
to native.

```sh
TAA_RENDER_SCALE=0.67 scripts/taa-launch.sh "$HOME/X-Plane 12/X-Plane.app"
```

- Leave `TAA_OUTPUT=native`. 5120×1440 is about 7.4 MP, fewer pixels than 4K,
  and `4k` would force a 16:9 image onto a 32:9 screen.
- In X-Plane, set **Rendering Resolution (FSR) = Off** so it doesn't upscale
  twice, and run full screen on the ultrawide.
- X-Plane ignores SIGTERM. Quit it from its own menu.
- The UI is rendered at the reduced size too, so text gets softer. Mouse
  mapping at reduced scale was **not tested**.
- X-Plane's built-in FSR is the supported way to do this. This injector exists
  only to study MetalFX and the TAA-lite pass.

### Settings (environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `TAA_ENABLE` | `1` | `0` disables all hooks. |
| `TAA_OUTPUT` | `native` | `native` (layer bounds × scale), `4k` (3840×2160), or `WxH`. |
| `TAA_UPSCALE` | `1` | `0` keeps output = render size (TAA-lite only). |
| `TAA_TEMPORAL` | `1` | `0` disables TAA-lite (upscale only). |
| `TAA_RENDER_SCALE` | `1.0` | 0.25–1.0. Forces a lower render size by reporting a smaller `drawableSize` to the game. Use it when the game has no resolution setting. |
| `TAA_BLEND` | `0.1` | Current-frame weight. Lower is smoother with more ghosting. |
| `TAA_CLAMP` | `1.25` | Variance clip size in std-devs. Higher is smoother with more ghosting. |
| `TAA_LOG` | `0` | Log sizes, hooks and resources to stderr. |
| `TAA_DUMP_FRAME` | – | Write the input and output of frame N as PNGs. |
| `TAA_DUMP_PREFIX` | `/tmp/taa_dump` | Path prefix for the dumps. |
| `TAA_INHERIT` | `0` | `1` passes the injector on to child processes. By default it's removed so browser helpers and crash reporters aren't injected. |

## Layout

```
src/taa_inject.m     hooks, proxy drawable, TAA-lite + MetalFX encoding
src/taa.metal        shaders (embedded into the dylib at build time)
test/testapp.m       minimal CAMetalLayer app to inject into
scripts/             launcher and copy-and-re-sign helper
```

## Plan

1. **Bootstrap repo.** *(done)*
2. **README and disclaimer.** *(done)*
3. **Spike the PoC:** runtime Metal interception, TAA-lite and MetalFX
   spatial upscale to native or 4K, plus a test app. *(done)*
4. **Write down what was learned.** Findings so far are under *Honest
   limitations*. In short: upscaling generically works; real TAA can't be done
   without engine data.
5. **Freeze.** No further maintenance is planned.

## License / Liability

Provided "as is", without warranty of any kind. The author(s) accept no
liability for any damage, breakage, or policy violation resulting from its use.
