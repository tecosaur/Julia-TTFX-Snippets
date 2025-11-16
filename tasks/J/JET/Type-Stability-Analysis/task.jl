# Task: Type Stability Analysis
# Package: JET
# Author: @gdalle
# Attribution: JET's docs
# Created: 2025-11-16
# Sample timings: install in 114.7s, run in 1.565s

__t1 = time()

using JET

__t2 = time()

add_one_first(x) = first(x) + 1
@report_opt add_one_first(Any[1])

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

