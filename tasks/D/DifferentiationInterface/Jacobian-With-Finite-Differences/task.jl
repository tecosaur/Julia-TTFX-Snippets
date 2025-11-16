# Task: Jacobian With Finite Differences
# Package: DifferentiationInterface
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 6.1s, run in 1.01s

__t1 = time()

using DifferentiationInterface

__t2 = time()

backend = DifferentiationInterface.AutoSimpleFiniteDiff()
f(x) = map(abs2, x)
x = rand(10)
jacobian(f, backend, x)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

