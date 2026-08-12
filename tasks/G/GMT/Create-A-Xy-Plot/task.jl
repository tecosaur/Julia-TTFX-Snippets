# Task: Create A Xy Plot
# Package: GMT
# Author: @joa-quim
# Created: 2025-05-10
# Sample timings: install in 221.5s, run in 7.601s

__t1 = time()

using GMT

__t2 = time()

plot(rand(5,2))
rm("gmt.history"; force=true)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

