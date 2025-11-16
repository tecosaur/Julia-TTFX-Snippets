# Task: Gradient Of Square Norm
# Package: ForwardDiff
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 14.4s, run in 0.909s

__t1 = time()

using ForwardDiff

__t2 = time()

f(x) = sum(abs2, x)
x = rand(10)
ForwardDiff.gradient(f, x)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

