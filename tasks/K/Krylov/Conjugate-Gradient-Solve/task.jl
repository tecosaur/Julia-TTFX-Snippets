# Task: Conjugate Gradient Solve
# Package: Krylov
# Dependencies: LinearAlgebra
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 11.0s, run in 2.143s

__t1 = time()

using Krylov, LinearAlgebra
using Krylov
using LinearAlgebra

__t2 = time()

A, b = rand(3, 3), rand(3)
S = 0.5 * (A + A') + I  # positive definite
cg(S, b)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

