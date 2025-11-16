# Task: Matrix Multiplication
# Package: StaticArrays
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 11.1s, run in 0.237s

__t1 = time()

using StaticArrays

__t2 = time()

M = @SMatrix randn(3, 3)
M * M

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

