# #62359 invalidates precompiled code on load: GMT's first plot goes 0.005s -> 3.8s

Bisected to [#62359](https://github.com/JuliaLang/julia/pull/62359) ("compiler: Separate local
inference proofs from code instances"). master only; 1.13 is unaffected.

First `plot(rand(5,2))` after `using GMT` (GMT v1.42.1, macOS aarch64, cold depot per build):

| build | elapsed | recompile_time | edge-validation events during `using GMT` |
|---|---|---|---|
| `ec06c23ce1` DEV.2873 (#62359's base) | 0.005s | **0.0s** | 2007 |
| `ec06c23ce1` + #62359 (`juliaup add pr62359`, DEV.2875) | 3.785s | **3.78s** | 5466 |
| DEV.2910 (current master) | 3.738s | 3.73s | 5939 |
| 1.13.0-rc2 | 0.011s | 0.0s | 74 |

Since #62359's base commit is also the last good commit, that build is base + this PR and nothing
else. Essentially the whole call is recompilation of code already in GMT's pkgimage.

## Repro

```julia
# julia --project=@gmt   (with GMT installed in an otherwise cold depot)
using GMT
Base.cumulative_compile_timing(true)
c0 = Base.cumulative_compile_time_ns()
@time plot(rand(5,2))          # 3.8s, of which ~3.78s is recompilation
c1 = Base.cumulative_compile_time_ns()
(c1[1] - c0[1], c1[2] - c0[2]) ./ 1e9   # (compile, recompile)
```

## Where it starts

`Base.ReinferUtils.debug_method_invalidation(true)` during `using GMT` begins with:

```
MethodInstance for getproperty(::Type{T} where T<:Tuple{Symbol, Any}, ::Symbol)
"insert_backedges_callee"
Any[getproperty(x::Core.TypeEgal, s::Symbol) @ Base deprecated.jl:666,
    getproperty(x::TypeEq,        s::Symbol) @ Base deprecated.jl:632]
```

`Core.TypeEgal` is a kind, so it intersects `Type{T}` and these deprecated methods join the match
set for `getproperty` on a type. It then cascades `DataTypeLayout` -> `datatype_alignment` ->
`aligned_sizeof` -> `unsafe_copyto!` -> `_growend!`, taking 2144 GMT code instances and 792 Base
ones with it.

Note the edge-validation count was already ~2000 before this PR — what changed is that these edges
now fail rather than pass.

## Scope

In a 39-task TTFX benchmark this is the largest single regression in the set: GMT's script-execution
step goes 0.010s on 1.13 to 3.50s on master (Linux x86_64), while its precompile and load times are
flat. Related, but a different mechanism: #61667.
