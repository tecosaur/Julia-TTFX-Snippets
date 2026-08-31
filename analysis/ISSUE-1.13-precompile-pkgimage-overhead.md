Claude:

---

# 1.13 re-infers already-compiled sysimage callees while generating every pkgimage: `Preferences` precompile 0.31s -> 0.68s

Precompiling a package costs noticeably more on 1.13.0-rc3 than on 1.12. The extra time is
type inference, re-run inside the image-generation phase on Base code that is already compiled
into the sysimage. It scales with how much Base code a package's compiled methods call, so it is
invisible behind a long compile but obvious on small packages and on dependency trees made of
many small ones. Still present on master.

This is not a global precompile regression: across the 39 TTFX tasks the median 1.12 -> 1.13
precompile change is about **-10%** (1.13 is faster), and package load is faster on 1.13 too.

## MWE

One package per environment, `compiled/` removed before each measurement, timing
`@elapsed Pkg.precompile()`:

| package | 1.11.9 | 1.12.7 | 1.13.0-rc3 | 1.13 backports (rc3.32) | nightly 1.14.0-DEV.3073 |
|---|---|---|---|---|---|
| `Preferences` | 0.31s | 0.28-0.31s | **0.68s** | 0.64-0.69s | 0.63s |
| `Static` | (no resolve) | 6.98-7.09s | **11.01s** | 9.98-10.15s | 9.27s |
| `StaticArrayInterface` (incl. `Static`) | | 8.28-8.33s | | 12.22-12.73s | |

An empty package (`module EmptyPkg end`) precompiles *faster* on 1.13 (0.12s vs 0.20s), so this
is not fixed per-image overhead.

## Mechanism

Since #59361 (1.13) the pkgimage worklist is compiled through `Compiler.compile_and_emit_native`
-> `typeinf_ext_toplevel` -> `compile!`. For every compiled body, `collectinvokes!` enqueues each
`:invoke` target, and `compile!` then demands its source (`typeinf_ext(...,
SOURCE_MODE_GET_SOURCE)`). Since #58172 / #58662 (also 1.13) sysimage `CodeInstance`s with native
code no longer retain inferred IR, so obtaining "source" for a Base callee means running inference
on it from scratch. The result is code-generated and then dropped again by `jl_emit_native`, which
already skips anything with `JL_CI_FLAGS_FROM_IMAGE` under external linkage (its comment: "TODO: for
performance, avoid generating the src code when we know it would reach here anyways").

On 1.12 the same `jl_emit_native` skip existed, but the source demand was satisfied by
`jl_uncompress_ir` because the 1.12 sysimage kept the IR (`ci.inferred::String`).

Reproduced in-process (pr62926) with the entry point `Preferences.load_preference(::UUID, ::String,
::Nothing)`, which is what the package's `precompile` statement compiles:

| | 1.12.7 | 1.13.0-rc3.32 |
|---|---|---|
| `typeinf_ext_toplevel([mi], [world], 0x0)` | 0.018s | **0.325s** |
| CodeInstances returned | 483 | 707 |
| of which already have native code | 483 | 707 |
| of which retain inferred IR | 481 | 20 |
| second call, same session | 0.006s | 0.28s |

By module the 707 are `Base` 487, `Base.TOML` 92, `Base.Filesystem` 38, `Core` 32, `Base.Sort` 30,
`Preferences` 3. The sysimage shrank 30.1 MB -> 26.8 MB between 1.12 and 1.13, which is the IR
that is gone.

Native sampling of the `Static` precompile child (12 s window, 1 ms) agrees: LLVM optimisation
threads take the same ~2.6 s on both versions; the main thread goes 4.6 s -> 7.7 s, and the whole
difference is `ijl_create_system_image -> jl_create_native_impl -> compile_and_emit_native ->
typeinf_ext_toplevel` (3104 samples, dominated by nested `const_prop_call`), plus ~900 samples of
`jl_emit_code` for the code that is then discarded. The only visible trace in the output is ccall
stubs: the 1.13 `Preferences` image carries 99 `jlplt_*` entries (`uv_fs_*`, `pcre2_*`,
`utf8proc_*`, ...) against 3 on 1.12, while its 11 `julia_*` functions are the same size.

Not the cause: process startup (faster on 1.13, 0.086s -> 0.071s), `-g0`/`-O0` (no change),
`Pkg`'s worker orchestration (`Base.compilecache` alone shows the full delta), the linker (~10 ms
both), LLVM 18 -> 20 (optimise+emit ~0.04 s both).

## Fix

Make `compile!` skip callees that already have native code from an image when generating a
package image (`external_linkage`, not trimming), which is precisely the set `jl_emit_native` was
going to discard anyway. With that skip in place in-process, the `load_preference` entry point
compiles in ~0 s and returns 1 CodeInstance instead of 707. Fix proposed in JuliaLang/julia#62934. Measured on a local build of `backports-release-1.13`
(1.13.0-rc3.32) with and without the patch, cold `compiled/` each time:

| | baseline | patched | 1.12.7 |
|---|---|---|---|
| `Base.compilecache(Preferences)` | 0.658s | **0.253s** | 0.31s |
| Static env `Pkg.precompile` | 10.01s | **5.11s** | 7.0s |
| StaticArrayInterface env | 11.89s | **6.35s** | 8.3s |
| ComponentArrays task tree | 13.32s | **7.61s** | 9.5-10.2s |
| ShareAdd task tree | 3.97s | **2.87s** | 3.2-3.6s |
| Preferences image size / `__text` / ccall stubs / `tojlinvoke` | 317,824 B / 19,420 / 99 / 0 | 256,768 B / 7,292 / 3 / 3 | 256,800 B / 7,356 / 3 / 3 |

The patched image has the same shape as 1.12's. Load and first-call times of the ComponentArrays
and ShareAdd tasks are unchanged (0.0755s/0.300s -> 0.0745s/0.298s and 0.207s/0.0064s ->
0.196s/0.0062s, best of 3).

A full 39-task sweep with the patch applied to both the 1.13 backports branch and master
(archived as `runs/2026-08-31_pr62934`) puts the whole-suite precompile geomean at **-19.7%**
vs the stock 1.13 arm (-10.3% after excluding the six cells the stock run's single
samples had inflated) and **-13.5%** vs stock nightly; load and first-call move with the same-day
1.12 control arm, i.e. unchanged. Relative to 1.10, the 1.13 arm's precompile geomean goes
from +11% (stock) to **-12%** (patched).

`#61920` (backported, in rc3.32) is adjacent but insufficient: it preserves IR for CIs newly
inferred in the child across the irgen boundary, which cannot help sysimage CIs whose IR was
stripped at sysimage build time (0.325s -> 0.316s measured). `#62658` changes edge recording and
does not touch this path.

## Task-level impact

From tecosaur/Julia-TTFX-Snippets tasks (cold `compiled/`, whole dependency tree precompiled):

| task | 1.10 | 1.11 | 1.12 | 1.13 | nightly |
|---|---|---|---|---|---|
| ComponentArrays/Basic-Manipulations | 5.88s | 5.03s | 9.50-10.18s | **13.56-14.15s** | 16.50s |
| ShareAdd/Get-Info-On-Stdlib-... | 3.88s | 3.72s | 3.18-3.62s | **4.08-5.05s** | 3.80s |

ComponentArrays' per-package breakdown attributes its gap to `Static` (6.03s -> 8.50s) and
`StaticArrayInterface` (0.93s -> 1.90s) on the critical path, plus `Preferences` (0.31s -> 0.70s)
and `PrecompileTools` (0.39s -> 0.70s). ShareAdd's tree is three packages; its whole delta is
`Preferences` (0.30s -> 0.70s) and `ShareAdd` itself (2.53s -> 2.90s). ComponentArrays also keeps
degrading on master (16.50s), so part of its story is separate from this.

## Repro

```console
$ export JULIA_DEPOT_PATH=/tmp/d:
$ julia +1.12 --project=/tmp/prefs -e 'using Pkg; Pkg.add("Preferences")'
$ for v in 1.12 1.13; do
    rm -rf /tmp/d/compiled
    julia +$v --project=/tmp/prefs -e 'using Pkg; @time Pkg.precompile()'
  done
```

In-process, without the precompile child:

```julia
using Preferences
C = Base.Compiler
m = only(methods(Preferences.load_preference, (Base.UUID, String, Nothing)))
mi = C.specialize_method(m, Tuple{typeof(Preferences.load_preference), Base.UUID, String, Nothing}, Core.svec())
@time out = C.typeinf_ext_toplevel(Any[mi], UInt[Base.get_world_counter()], 0x0)   # 0.02s on 1.12, 0.3s on 1.13
count(x -> x isa Core.CodeInstance, out)                                            # 483 vs 707, all already compiled
```

## Environment

macOS 15 (Darwin 25.6.0), Apple M5 Pro, `arm64-apple-darwin`. Builds: 1.11.9, 1.12.7,
1.13.0-rc3 (`a861d5fe286`), 1.13 backports branch via `juliaup add pr62926` (1.13.0-rc3.32,
`1483760d1ed`), nightly 1.14.0-DEV.3073 (`ba658ebd8c2`). Every number above is from repeated
measurements with the two versions alternated back to back.

## Related

- #59361 moved the pkgimage precompile driver from C to `Compiler.compile_and_emit_native`.
- #58172 / #58662 stopped storing large inferred IR in the sysimage.
- #62723 (1.13.0-rc3 -> nightly TTFX regressions) covers the master-only side, including
  the Mooncake case and #61714.
