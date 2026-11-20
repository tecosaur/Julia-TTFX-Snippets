# Task: Diffusion Tendency On Sphere
# Package: ClimaCore
# Author: @ph-kev
# Created: 2026-11-20
# Sample timings: install in 143.4s, run in 9.971s

__t1 = time()

using ClimaCore: CommonSpaces, Fields, Operators

__t2 = time()

space = CommonSpaces.ExtrudedCubedSphereSpace(; z_elem = 10, z_min = 0, z_max = 1,
    radius = 10, h_elem = 4, n_quad_points = 4, staggering = CommonSpaces.CellCenter())
θ = 300 .+ 10 .* Fields.coordinate_field(space).z
K(θ) = 1 + tanh(θ / 300 - 1)
ᶠinterp = Operators.InterpolateC2F(bottom = Operators.Extrapolate(), top = Operators.Extrapolate())
ᶠgrad = Operators.GradientC2F(bottom = Operators.SetValue(300.0), top = Operators.SetValue(310.0))
ᶜdiv = Operators.DivergenceF2C()
θₜ = @. ᶜdiv(ᶠinterp(K(θ)) * ᶠgrad(θ))

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

