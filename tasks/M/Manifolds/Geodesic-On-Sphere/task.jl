# Task: Geodesic On Sphere
# Package: Manifolds
# Author: @gdalle
# Attribution: Manifolds' README
# Created: 2025-11-16
# Sample timings: install in 38.0s, run in 1.465s

__t1 = time()

using Manifolds

__t2 = time()

M = Sphere(2)
γ = shortest_geodesic(M, [0.0, 0.0, 1.0], [0.0, 1.0, 0.0])
γ(0.5)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

