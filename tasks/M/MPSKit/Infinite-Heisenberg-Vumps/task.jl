# Task: Infinite Heisenberg Vumps
# Package: MPSKit
# Dependencies: TensorKit
# Author: @hz-xiaxz
# Created: 2026-11-20
# Sample timings: install in 767.9s, run in 281.2s

__t1 = time()

using MPSKit, TensorKit

__t2 = time()

P = SU2Space(1 // 2 => 1)
h = zeros(ComplexF64, P ⊗ P ← P ⊗ P)
block(h, SU2Irrep(0)) .= -3 / 4
block(h, SU2Irrep(1)) .= 1 / 4
H = InfiniteMPOHamiltonian([P, P], (1, 2) => h, (2, 3) => h)
ψ = InfiniteMPS([P, P], [SU2Space(0 => 3, 1 => 2), SU2Space(1 // 2 => 3, 3 // 2 => 1)])
ψ, = find_groundstate(ψ, H, VUMPS(; maxiter = 2, verbosity = 0))

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")
