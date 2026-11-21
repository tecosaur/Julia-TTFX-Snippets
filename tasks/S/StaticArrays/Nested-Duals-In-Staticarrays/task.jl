# Task: Nested Duals In Staticarrays
# Package: StaticArrays
# Dependencies: ForwardDiff
# Author: @pkofod
# Created: 2026-11-20
# Sample timings: install in 19.1s, run in 40.714s

__t1 = time()

using ForwardDiff, StaticArrays, LinearAlgebra

__t2 = time()

# Oral one-compartment model at steady state, in closed form: x(t) = exp(A t) x₀ with
# x₀ = (I - exp(A τ)) \ b for doses b every τ hours.
const τ = 12.0
const times = SVector(0.5, 1.0, 2.0, 4.0, 6.0, 8.0, 11.0)

function concentrations(θ, η)
    ka = exp(θ[1] + η[1])
    cl = exp(θ[2] + η[2])
    v = exp(θ[3] + η[3])
    A = @SMatrix [-ka 0; ka -cl/v]
    x₀ = (I - exp(A * τ)) \ SVector(100.0, 0.0)
    return map(t -> (exp(A * t) * x₀)[2] / v, times)
end

# Negative log-likelihood of one subject: proportional error and a normal prior on η.
function nll(θ, η, y)
    c = concentrations(θ, η)
    σ = exp(θ[7])
    ω = exp.(SVector(θ[4], θ[5], θ[6]))
    r = (y .- c) ./ (σ .* c)
    return sum(abs2, r) / 2 + sum(log.(σ .* c)) + sum(abs2, η ./ ω) / 2 + sum(log, ω)
end

# Laplace approximation: damped Newton steps to the mode of η, then the log-determinant of
# the Hessian there. The outer gradient over θ differentiates through all of it.
function laplace(θ, y)
    f = η -> nll(θ, η, y)
    η = zero(SVector{3, eltype(θ)})
    for _ in 1:4
        Δ = ForwardDiff.hessian(f, η) \ ForwardDiff.gradient(f, η)
        for _ in 1:10
            f(η - Δ) < f(η) && break
            Δ = Δ / 2
        end
        η = η - Δ
    end
    return f(η) + log(det(ForwardDiff.hessian(f, η))) / 2
end

θ = SVector(log(1.2), log(5.0), log(50.0), log(0.3), log(0.3), log(0.3), log(0.15))
data = [concentrations(θ, 0.1 .* (i - 3) .* SVector(1.0, 0.8, 0.5)) .* (1 .+ 0.1 .* sin.(i .* SVector{7}(1:7)))
        for i in 1:5]

objective(θ) = sum(y -> laplace(θ, y), data)
objective(θ)
ForwardDiff.gradient(objective, θ)

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

