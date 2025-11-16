# Task: Format Text
# Package: JuliaFormatter
# Author: @gdalle
# Attribution: Guillaume Dalle
# Created: 2025-11-16
# Sample timings: install in 53.0s, run in 0.14s

__t1 = time()

using JuliaFormatter

__t2 = time()

format_text("using  JuliaFormatter")

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

