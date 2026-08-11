# GMT.jl's precompiled code is invalidated on load on 1.14: 5959 edge-validation events, first call ~40x slower

On 1.14, the first `plot(rand(5,2))` after `using GMT` is **99.5% recompilation** of code that
was already compiled into GMT's pkgimage. On 1.12 and 1.13 the same call does no
recompilation at all.

```julia
using GMT
r = @timed plot(rand(5,2))     # r.recompile_time is the interesting field
```

| Julia | elapsed | compile_time | recompile_time |
|---|---|---|---|
| 1.12.6 | 0.017s | 0.010s | **0.000s** |
| 1.13.0-rc1.105 | 0.012s | 0.007s | **0.000s** |
| 1.14.0-DEV.2894 | 0.458s | 0.453s | **0.450s** |

Fresh compilation is not the problem: `--trace-compile-timing` accounts for only **51.5ms
across 61 methods**, nearly all of them small `Base` utilities. The remaining ~400ms is
re-inference of code that should have come from the pkgimage.

## Where it comes from

Counting invalidations during `using GMT` only:

```julia
listi = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
liste = Base.ReinferUtils.debug_method_invalidation(true)   # Base.StaticData before the rename
@eval using GMT
ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
Base.ReinferUtils.debug_method_invalidation(false)
(length(listi), length(liste))
```

| Julia | method-invalidation log | edge-validation log |
|---|---|---|
| 1.12.6 | 239 | 219 |
| 1.13.0-rc1.105 | 102 | **74** |
| 1.14.0-DEV.2894 | 174 | **5959** |

The classic method-invalidation path is unchanged — it actually shrinks. The regression is
entirely in pkgimage **edge validation**, up ~80x from 1.13, and 1.13 is the cleanest of the
three. Whatever fails verification there takes GMT's cached `plot` path with it.

## Not universal

`ComponentArrays` in the same setup is flat across the same boundary — 282 edge-validation
events on 1.13, 261 on nightly — so this is not something every package hits, and I have not
reduced it to a smaller reproducer than GMT. Identifying what distinguishes GMT is the
obvious next step; it is a large package (~126s to precompile) with a substantial
`@compile_workload`, so it has far more cached code to lose than most.

## Impact

Measured in a TTFX benchmark, GMT's script-execution step goes **0.0099s on 1.13-nightly to
3.62s on nightly (367x)** on a Linux x86_64 box, and 0.012s → 0.458s on macOS x86_64. The
mechanism is `recompile_time` in both cases; the absolute gap differs with hardware.

Precompilation and load time are flat-to-improving over the same step, so the package
precompiles fine — the cached code simply isn't usable afterwards. Unlike invalidation
problems that a package can dodge by restructuring its own precompile workload, there is
nothing obvious for GMT to do here.

## Environment

macOS x86_64, GMT v1.42.1, cold depot per version. Comparison versions 1.12.6 and
1.13.0-rc1.105 both show zero recompilation, so the change is 1.14-only.
