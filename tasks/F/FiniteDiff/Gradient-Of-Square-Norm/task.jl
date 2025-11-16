# Task: Gradient Of Square Norm
# Package: FiniteDiff
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 9.4s, run in 0.508s

__t1 = time()

using FiniteDiff

__t2 = time()

f(x) = sum(abs2, x)
x = rand(10)
FiniteDiff.finite_difference_gradient(f, x)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

