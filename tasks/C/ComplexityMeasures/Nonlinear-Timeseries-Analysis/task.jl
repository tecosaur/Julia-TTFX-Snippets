# Task: Nonlinear Timeseries Analysis
# Package: ComplexityMeasures
# Author: @Datseris
# Created: 2025-10-13
# Sample timings: install in 61.1s, run in 3.238s

__t1 = time()

using ComplexityMeasures

__t2 = time()

x = randn(1000)
e = entropy(OrdinalPatterns{4}(), x)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

