# Task: Normal Distribution
# Package: Distributions
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 21.4s, run in 0.672s

__t1 = time()

using Distributions

__t2 = time()

d = Normal(2.0, 1.0)
x = rand(d, 100)
logpdf(d, x)
fit(Normal, x)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

