# Task: Basic Coloring
# Package: SparseMatrixColorings
# Dependencies: SparseArrays
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 12.8s, run in 0.342s

__t1 = time()

using SparseMatrixColorings, SparseArrays
using SparseMatrixColorings
using SparseArrays

__t2 = time()

problem = ColoringProblem()
algo = GreedyColoringAlgorithm()
S = sprand(Bool, 100, 200, 0.05)
result = coloring(S, problem, algo)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

