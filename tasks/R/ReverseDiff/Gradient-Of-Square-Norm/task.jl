# Task: Gradient Of Square Norm
# Package: ReverseDiff
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 35.2s, run in 3.622s

__t1 = time()

using ReverseDiff

__t2 = time()

f(x) = sum(abs2, x)
x = rand(10)
ReverseDiff.gradient(f, x)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

