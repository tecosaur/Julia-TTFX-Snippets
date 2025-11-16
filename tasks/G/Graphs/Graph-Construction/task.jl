# Task: Graph Construction
# Package: Graphs
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 18.5s, run in 0.758s

__t1 = time()

using Graphs

__t2 = time()

g = SimpleGraph(10, 20)
add_vertex!(g)
add_edge!(g, 10, 11)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

