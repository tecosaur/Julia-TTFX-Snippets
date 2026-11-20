# Task: Finite Heisenberg Dmrg
# Package: MPSKit
# Dependencies: TensorKit
# Author: @hz-xiaxz
# Created: 2026-11-20
# Sample timings: install in 591.7s, run in 155.0s

__t1 = time()

using MPSKit, TensorKit

__t2 = time()

P = SU2Space(1 // 2 => 1)
h = zeros(ComplexF64, P ⊗ P ← P ⊗ P)
block(h, SU2Irrep(0)) .= -3 / 4
block(h, SU2Irrep(1)) .= 1 / 4
L = 12
H = FiniteMPOHamiltonian(fill(P, L), (i, i + 1) => h for i in 1:(L - 1))
ψ = FiniteMPS(L, P, SU2Space(0 => 2, 1 // 2 => 2, 1 => 2))
ψ, = find_groundstate(ψ, H, DMRG2(; maxiter = 2, verbosity = 0, trunc = truncrank(20)))

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")
