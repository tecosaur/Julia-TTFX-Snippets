# Task: Addition With Uncertainties
# Package: Measurements
# Author: @gdalle
# Attribution: Measurements' README
# Created: 2025-11-16
# Sample timings: install in 5.9s, run in 0.092s

__t1 = time()

using Measurements

__t2 = time()

a = measurement(4.5, 0.1)
b = 3.8 ± 0.4
2a + b

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

