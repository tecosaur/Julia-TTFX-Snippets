# Recompiling invalidated MethodInstances is ~35x more expensive per instance on 1.12+

Precompiling `Static.jl` v1.4.6 went from **1.2s on 1.11 to 32.5s on nightly**. All of it comes
from one block:

```julia
@recompile_invalidations begin
    import CommonWorldInvalidations
end
```

`@recompile_invalidations` (PrecompileTools) calls `precompile` on every MethodInstance
invalidated inside the block. Deleting just the wrapper, keeping the `import`:

| Julia | stock | wrapper removed |
|---|---|---|
| 1.11.9 | 1.20s | 0.93s |
| 1.12.6 | 18.6s | 2.72s |
| 1.13.0-rc1.105 | 28.0s | 0.80s |
| 1.14.0-DEV.2894 | 32.5s | 1.30s |
| 1.14.0-DEV.2895 + [#62658](https://github.com/JuliaLang/julia/pull/62658) | **6.7s** | — |

## Reproducer

```julia
using PrecompileTools   # v1.2.1 on 1.11, v1.3.4 on 1.12+
const RU = isdefined(Base, :ReinferUtils) ? Base.ReinferUtils : Base.StaticData
listi = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
liste = RU.debug_method_invalidation(true)          # 1.12+ only
try
    @eval import CommonWorldInvalidations           # v1.1.2
finally
    ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
    RU.debug_method_invalidation(false)
end
leaves = PrecompileTools.invalidation_leaves(listi, liste)
@time foreach(PrecompileTools.precompile_mi, leaves)
```

| Julia | leaf MethodInstances | recompile | per instance |
|---|---|---|---|
| 1.11.9 | 20 | 0.05s | ~2.5ms |
| 1.12.6 | 279 | 22.3s | ~80ms |
| 1.13.0-rc1.105 | 256 | 21.0s | ~82ms |
| 1.14.0-DEV.2894 | 208 | 23.8s | ~114ms |
| 1.14.0-DEV.2895 + [#62658](https://github.com/JuliaLang/julia/pull/62658) | **68** | **1.21s** | ~18ms |

Two things changed. The invalidation blast radius grew (20 → 279 leaves), which may be
expected if 1.12+ caches more inferred code. But the **per-instance recompilation cost grew
32-45x**, and the leaf count is now *falling* while total time keeps rising — that part looks
like a genuine regression.

The 1.12+ edge-validation source (`Base.StaticData`/`ReinferUtils`) contributes **0 entries**
here, so this is entirely the classic method-invalidation path.

## #62658 fixes most of this

[JuliaLang/julia#62658](https://github.com/JuliaLang/julia/pull/62658) applies
`concrete_only = true` to `!=`, `>`, `>=`, `|` and `&`. `!=` and `>=` are among the triggers
`CommonWorldInvalidations` inserts, and on that build the leaf count drops 208 → 68 and the
recompilation cost 23.8s → 1.21s, taking `Static.jl` from 32.5s to 6.7s.

That is a ~20x cut without touching either package, and it also brings the per-instance cost
back from ~114ms to ~18ms, which suggests the two effects were not independent: much of the
apparent per-instance cost was the expense of re-inferring these particular operator-rooted
trees. A residual gap remains — 6.7s against 1.2s on 1.11, or 1.3s with the macro deleted —
so the packages would still benefit from dropping `@recompile_invalidations`.

## Impact

`Static.jl` and `StaticArrayInterface.jl` both use this macro and sit deep in the
ArrayInterface/SciML tree. A `ComponentArrays` environment precompiles in 7.9s on 1.11 and
56.1s on nightly, with those two accounting for all of the growth (ComponentArrays itself is
flat at ~1.2s).

Packages can drop the macro as a workaround — that recovers nearly all of it — but the
per-instance cost seems worth understanding independently.

Measured on macOS x86_64, cold compiled cache per measurement.
