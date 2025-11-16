# Task: Rosenbrock Minimization With Bfgs
# Package: Optim
# Author: @gdalle
# Attribution: Optim's README
# Created: 2025-11-16
# Sample timings: install in 28.8s, run in 3.348s

__t1 = time()

using Optim

__t2 = time()

rosenbrock(x) = (1.0 - x[1])^2 + 100.0 * (x[2] - x[1]^2)^2
result = optimize(rosenbrock, zeros(2), BFGS())

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

