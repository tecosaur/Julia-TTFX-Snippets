# Task: Multistability Of Discrete Time Systems
# Package: Attractors
# Author: @Datseris
# Created: 2025-10-13
# Sample timings: install in 125.9s, run in 4.084s

__t1 = time()

using Attractors

__t2 = time()

function henon_rule(u, p, n) # here `n` is "time", but we don't use it.
    x, y = u # system state
    a, b = p # system parameters
    xn = 1.0 - a*x^2 + y
    yn = b*x
    return SVector(xn, yn)
end
u0 = [0.2, 0.3]
p0 = [1.4, 0.3]
henon = DeterministicIteratedMap(henon_rule, u0, p0)
xg = yg = range(-2, 2; length = 201)
mapper = AttractorsViaRecurrences(henon, (xg, yg); sparse = false)
basins, attractors = basins_of_attraction(mapper; show_progress = false)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

