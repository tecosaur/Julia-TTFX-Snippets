# Task: Basic Benchmark
# Package: BenchmarkTools
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 22.3s, run in 2.2s

__t1 = time()

using BenchmarkTools

__t2 = time()

x = 1.0
@benchmark exp($x)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

