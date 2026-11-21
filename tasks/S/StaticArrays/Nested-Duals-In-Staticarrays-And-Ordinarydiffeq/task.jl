# Task: Nested Duals In Staticarrays And Ordinarydiffeq
# Package: StaticArrays
# Dependencies: OrdinaryDiffEqRosenbrock, OrdinaryDiffEqVerner, ADTypes, ForwardDiff
# Author: @pkofod
# Created: 2026-11-20
# Sample timings: install in 142.4s, run in 42.123s

__t1 = time()

using OrdinaryDiffEqRosenbrock, OrdinaryDiffEqVerner, ADTypes, ForwardDiff, StaticArrays, LinearAlgebra

__t2 = time()

# Fast first-order absorption into Michaelis-Menten elimination. The fast absorption makes
# the system stiff, so AutoVern7 switches to Rodas5P.
function oral_mm(u, p, t)
    depot, central = u
    ka, vmax, km, v = p
    c = central / v
    return SVector(-ka * depot, ka * depot - vmax * c / (km + c))
end

const alg = AutoVern7(Rodas5P(autodiff = AutoForwardDiff(chunksize = 1)))
const times = [1.0, 4.0, 12.0, 24.0, 48.0, 72.0]

function concentrations(θ, η)
    p = SVector(exp(θ[1] + η[1]), exp(θ[2] + η[2]), exp(θ[3]), exp(θ[4] + η[3]))
    u₀ = SVector(100, 0) .* one(eltype(p))
    sol = solve(ODEProblem{false}(oral_mm, u₀, (0.0, 72.0), p), alg;
                saveat = times, abstol = 1e-10, reltol = 1e-8)
    return SVector{6}(map(u -> u[2] / p[4], sol.u))
end

# Proportional-error residuals and the negative log-likelihood of one subject, with a
# normal prior on η.
function residuals(θ, η, y)
    c = concentrations(θ, η)
    return (y .- c) ./ (exp(θ[8]) .* c)
end

function nll(θ, η, y)
    c = concentrations(θ, η)
    σ = exp(θ[8])
    ω = exp.(SVector(θ[5], θ[6], θ[7]))
    return sum(abs2, (y .- c) ./ (σ .* c)) / 2 + sum(log.(σ .* c)) + sum(abs2, η ./ ω) / 2 +
           sum(log, ω)
end

# FOCE-style approximation: damped Gauss-Newton steps to the mode of η, then the
# log-determinant of the Gauss-Newton Hessian there. The outer gradient over θ
# differentiates through all of it.
function foce(θ, y)
    f = η -> nll(θ, η, y)
    Ωinv = Diagonal(exp.(-2 .* SVector(θ[5], θ[6], θ[7])))
    H = η -> (J = ForwardDiff.jacobian(η -> residuals(θ, η, y), η); J' * J + Ωinv)
    η = zero(SVector{3, eltype(θ)})
    for _ in 1:4
        Δ = H(η) \ ForwardDiff.gradient(f, η)
        for _ in 1:10
            f(η - Δ) < f(η) && break
            Δ = Δ / 2
        end
        η = η - Δ
    end
    return f(η) + logdet(H(η)) / 2
end

θ = SVector(log(20.0), log(2.0), log(2.0), log(5.0), log(0.3), log(0.3), log(0.3), log(0.15))
data = [concentrations(θ, 0.1 .* (i - 2) .* SVector(1.0, 0.8, 0.5)) .* (1 .+ 0.1 .* sin.(i .* SVector{6}(1:6)))
        for i in 1:3]

objective(θ) = sum(y -> foce(θ, y), data)
objective(θ)
ForwardDiff.gradient(objective, θ)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

