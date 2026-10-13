# GMT: precompiled code invalidated on load — the 1.14 escalation

**This is not a new issue.** [JuliaLang/julia#61667](https://github.com/JuliaLang/julia/issues/61667)
("Invalidations in GMT exist in 1.13 but do not exist in 1.12") already tracks it, and the
root causes for the 1.12 → 1.13 step have been identified there. What follows is the
additional 1.14 data, which is *not* explained by those causes and looks like a separate
regression. It is written to be posted as a comment on 61667.

## What 61667 already established

- **Binding invalidation (JamesWrigley, Aug 6).** The 317ms `GMT.axis` recompile on 1.13 comes
  from `Main.Symbol` rebinding invalidating a constant-propagated
  `Base.isvisible(::Symbol, ::Module, ::Module)`, which cascades through the whole show/print
  stack into `axis()` via string interpolation of `keys(d)`. Proposed: `@constprop :none` on
  `isvisible`, or stop the compiler treating this as invalidating.
- **Static backedges from abstract iteration (adienes, Jul 31).** PR #58635 split
  `iterate_starting_state`, so for abstract `A` inference union-splits and emits a static edge
  into `eachindex(::IndexLinear, ::AbstractVector{T})` where 1.12 had none. Any package
  defining `eachindex(::IndexLinear, ::MyArray)` or `iterate(::MyArray, ...)` then invalidates
  every poorly-inferred `for x in a` in precompiled code; SparseArrays' `ReadOnly` does both.
- **Trigger surface (KristofferC).** `resize!(x::ReadOnly, l)` should constrain `l::Integer`;
  GMT's `names(::Vector{<:GMTdataset})` is type piracy.

## The 1.14 data

First `plot(rand(5,2))` after `using GMT` (GMT v1.42.1, macOS x86_64, cold depot per version):

| Julia | elapsed | compile_time | recompile_time |
|---|---|---|---|
| 1.12.6 | 0.017s | 0.010s | **0.000s** |
| 1.13.0-rc1.105 | 0.012s | 0.007s | **0.000s** |
| 1.14.0-DEV.2894 | 0.507s | 0.501s | **0.499s** |

On 1.14 essentially the whole call is recompilation of code already in GMT's pkgimage; 1.12
and 1.13 do none. `--trace-compile-timing` shows ~64 methods compiled during the call summing
to about the same total as `compile_time` — the trace includes recompilation, so it does not
by itself separate the two; `recompile_time` is what does. The call is noisy run to run
(0.46s-1.15s on one build), so compare `recompile_time`, not wall time.

Invalidations during `using GMT` alone:

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
| 1.14.0-DEV.2895 + #62658 | 174 | **5959** |

The invalidation *sources* barely move (102 → 174). What grows ~80x is pkgimage **edge
validation**, and #62658 leaves the count byte-identical — so this is not the
`!=`/`>`/`>=`/`|`/`&` class, and operator-level `concrete_only` work will not touch it. The
amplification appears to be in how 1.14 verifies and re-infers pkgimage edges rather than in
new invalidation triggers.

## Scope

`ComponentArrays` across the same boundary is flat — 282 edge-validation events on 1.13, 261
on nightly — so this is not universal, and I have not reduced it below GMT as a reproducer.
GMT is large (~120s to precompile) with a substantial `@compile_workload`, so it has far more
cached code to lose than most packages.

**Caveat vs the issue title:** by these raw log counts 1.13 is the *cleanest* of the three
versions and does zero recompilation, which does not match "1.13 worse than 1.12". That is
most likely a difference in metric — log entries during load versus invalidated user code via
SnoopCompile — rather than a contradiction, but the numbers should not be read as confirming
the original report.

## Impact

In a 39-task TTFX benchmark, GMT's script-execution step goes 0.0099s on 1.13-nightly to
3.62s on nightly (367x) on Linux x86_64 — the largest single regression in the set — while
its precompile and load times are flat-to-improving. Unlike the `@recompile_invalidations`
problem in [ISSUE-recompile-invalidations.md](ISSUE-recompile-invalidations.md), there is no
package-side workaround: GMT precompiles fine, the cached code just isn't usable afterwards.
