# Task: Loading A Typical Hep-Ex .Root File
# Package: UnROOT
# Author: @Moelf
# Created: 2025-11-14
# Sample timings: install in 136.7s, run in 8.935s

__t1 = time()

using UnROOT

__t2 = time()

LazyTree(UnROOT.samplefile("NanoAODv5_sample.root"), "Events");

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

