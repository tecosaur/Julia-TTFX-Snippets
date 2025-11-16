# Task: Matrix Multiplication On Gpu-Like Arrays
# Package: JLArrays
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 28.7s, run in 2.739s

__t1 = time()

using JLArrays

__t2 = time()

A = jl(rand(3, 3))
b = jl(rand(3))
A * b

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

