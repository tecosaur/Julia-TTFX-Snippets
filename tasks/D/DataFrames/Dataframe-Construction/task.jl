# Task: Dataframe Construction
# Package: DataFrames
# Author: @gdalle
# Attribution: DataFrames documentation
# Created: 2025-11-16
# Sample timings: install in 87.4s, run in 0.735s

__t1 = time()

using DataFrames

__t2 = time()

DataFrame(A=1:3, B=5:7)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

