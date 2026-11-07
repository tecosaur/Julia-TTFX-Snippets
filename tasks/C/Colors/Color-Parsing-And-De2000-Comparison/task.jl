# Task: Color Parsing And De2000 Comparison
# Package: Colors
# Author: @kimikage
# Created: 2026-11-07
# Sample timings: install in 12.4s, run in 1.094s

__t1 = time()

using Colors

__t2 = time()

function report_de2000(io::IO, colors)
    d_max = 0.0f0
    p_max = (first(colors), first(colors))

    for c1 in colors, c2 in colors
        d = colordiff(c1, c2)
        if d > d_max
            d_max = d
            p_max = (c1, c2)
        end
    end

    println(io, "The pair with the largest color difference:")
    println(io, collect(p_max))
    println(io, "ΔE₀₀: $d_max")
    return
end

strs = ["royalblue" "rgb(22%, 59.6%, 14.9%)"
        "rgb(149, 88, 178)" "#CB3C33"]

iob = IOBuffer()
report_de2000(iob, parse.(RGB, strs))

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

