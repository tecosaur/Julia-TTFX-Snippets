# Task: Basic Manipulations
# Package: ComponentArrays
# Author: @gdalle
# Attribution: ComponentArrays' README
# Created: 2025-11-16
# Sample timings: install in 29.9s, run in 1.178s

__t1 = time()

using ComponentArrays

__t2 = time()

c = (a = 2, b = [1, 2])
x = ComponentArray(a = 5, b = [(a = 20.0, b = 0), (a = 33.0, b = 0), (a = 44.0, b = 3)], c = c)
x.c.a = 400
x[8]
collect(x)
similar(x, Int)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

