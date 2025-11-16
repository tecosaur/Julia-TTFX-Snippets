# Task: Dot Product
# Package: LoopVectorization
# Author: @gdalle
# Attribution: LoopVectorization's README
# Created: 2025-11-16
# Sample timings: install in 66.7s, run in 1.537s

__t1 = time()

using LoopVectorization

__t2 = time()

function mydotavx(a, b)
    s = zero(Base.promote_eltype(a, b))
    @turbo for i in eachindex(a, b)
        s += a[i] * b[i]
    end
    return s
end

mydotavx(rand(255), rand(255))

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

