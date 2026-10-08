# Task: Load And Unload Env File
# Package: DotEnv
# Author: @tecosaur
# Created: 2026-10-08
# Sample timings: install in 7.9s, run in 0.329s

__t1 = time()

using DotEnv

__t2 = time()

mktempdir() do dir
    write(joinpath(dir, ".env"), """
        # Comment line
        APP_NAME=MyApp
        export APP_ENV = development   # inline comment
        DB_HOST: localhost
        DB_PORT=5432
        DB_URL="postgres://\${DB_HOST}:\${DB_PORT}/\${APP_NAME}"
        GREETING='single \$quoted literal'
        MULTILINE="line1\\nline2"
        EMPTY=
        WITH_DEFAULT=\${UNSET_VAR_XYZ:-fallback}
        """)
    env = Dict{String, String}("APP_ENV" => "preexisting")
    DotEnv.load!(env, dir)
    DotEnv.unload!(env)
end

__t3 = time()

__t_using = __t2 - __t1
__t_script = __t3 - __t2
__t_total = __t3 - __t1
println(stdout, "$__t_using, $__t_script, $__t_total seconds")

