# Task: Rosenbrock Minimization With Bfgs Using Forwarddiff
# Package: Optimization
# Dependencies: OptimizationOptimJL, ForwardDiff
# Author: @gdalle
# Attribution: Optimization's README
# Created: 2025-11-16
# Sample timings: install in 73.2s, run in 3.322s

__t1 = time()

using Optimization, OptimizationOptimJL, ForwardDiff
using Optimization
using OptimizationOptimJL
using ForwardDiff

__t2 = time()

rosenbrock(x, p) = (p[1] - x[1])^2 + p[2] * (x[2] - x[1]^2)^2
x0 = zeros(2)
p = [1.0, 100.0]
f = OptimizationFunction(rosenbrock, Optimization.AutoForwardDiff())
prob = OptimizationProblem(f, x0, p)
sol = solve(prob, BFGS())

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

