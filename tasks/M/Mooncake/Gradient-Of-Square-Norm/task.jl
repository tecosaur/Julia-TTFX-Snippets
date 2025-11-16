# Task: Gradient Of Square Norm
# Package: Mooncake
# Dependencies: DifferentiationInterface
# Author: @gdalle
# Attribution: Mooncake's README
# Created: 2025-11-16
# Sample timings: install in 88.2s, run in 32.213s

__t1 = time()

using Mooncake, DifferentiationInterface
using Mooncake
using DifferentiationInterface

__t2 = time()

f(x) = sum(abs2, x)
x = rand(10)
gradient(f, AutoMooncake(), x)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

