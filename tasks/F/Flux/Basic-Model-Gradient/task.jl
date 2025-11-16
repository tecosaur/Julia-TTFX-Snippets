# Task: Basic Model Gradient
# Package: Flux
# Author: @gdalle
# Attribution: Flux's docs
# Created: 2025-11-16
# Sample timings: install in 104.1s, run in 17.597s

__t1 = time()

using Flux

__t2 = time()

model = Chain(Dense(10 => 1, σ), only)
Flux.gradient(|>, ones(Float32, 10), model)[2]

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

