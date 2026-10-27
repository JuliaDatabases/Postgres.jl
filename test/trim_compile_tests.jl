# Compiles test/postgres_trim_queries.jl with juliac, requires a clean verifier
# report apart from known stdlib gaps, and runs the executable against the test
# database. `--trim=unsafe-warn` builds despite reported errors. Executing this
# workload verifies its runtime paths, not strict `--trim=safe` support.
import Pkg

const _TRIM_SUPPORTED = VERSION >= v"1.12.0-rc1" && isempty(VERSION.prerelease)
const _JULIAC_ENTRYPOINT_EXPR = "using JuliaC; if isdefined(JuliaC, :main); JuliaC.main(ARGS); else JuliaC._main_cli(ARGS); end"
const _TRIM_COMPILE_TIMEOUT_S = parse(Float64, get(ENV, "POSTGRES_TRIM_COMPILE_TIMEOUT_S", "600"))
const _TRIM_RUN_TIMEOUT_S = parse(Float64, get(ENV, "POSTGRES_TRIM_EXE_TIMEOUT_S", "60"))

function _prepare_trim_project(trim_project::String)::Nothing
    mkpath(trim_project)
    cp(joinpath(@__DIR__, "trim", "Project.toml"), joinpath(trim_project, "Project.toml"))
    original_project = Base.active_project()
    try
        Pkg.activate(trim_project)
        Pkg.develop(Pkg.PackageSpec(path = pkgdir(Postgres)))
        Pkg.instantiate()
    finally
        original_project === nothing || Pkg.activate(original_project)
    end
    return nothing
end

function _run_with_timeout(cmd::Cmd; timeout_s::Float64, label::String)
    # JuliaC and its compiler subprocess share these streams. A pipe keeps
    # their writes ordered without competing regular-file offsets.
    pipe = Pipe()
    captured = IOBuffer()
    exit_code, timed_out = -1, false
    proc = run(pipeline(ignorestatus(cmd), stdout = pipe, stderr = pipe); wait = false)
    close(pipe.in)
    reader = @async try
        while !eof(pipe)
            write(captured, readavailable(pipe))
        end
    catch err
        timed_out || rethrow()
    end
    started_at = time()
    while Base.process_running(proc)
        if time() - started_at >= timeout_s
            timed_out = true
            kill(proc)
            break
        end
        sleep(0.1)
    end
    timed_out ? close(pipe) : wait(proc)
    wait(reader)
    close(pipe)
    exit_code = something(proc.exitcode, -1)
    output = String(take!(captured))
    timed_out && error("trim $(label) timed out after $(timeout_s)s:\n$(output)")
    return exit_code, output
end

# Released Julia's Base64 pipes and Dates.CompoundPeriod constructor are not
# trim-safe (SASLAuth's SCRAM exchange and interval decoding reach them). An
# error whose stdlib frames, before the first package frame, pass through those
# files is reported but not counted.
function _stdlib_trim_gap(error_text::AbstractString)::Bool
    for m in eachmatch(r"\n\s+@ (\S+) (\S+):\d+", error_text)
        mod, path = m.captures
        occursin(r"/Base64/src/|/Dates/src/periods\.jl", path) && return true
        (mod == "Core" || mod == "Base" || startswith(mod, "Base.")) || return false
    end
    return false
end

function _trim_verify_counts(output::String)
    blocks = split("\n" * output, r"\n(?:Verifier error|Error) #\d+:")[2:end]
    gaps = count(_stdlib_trim_gap, blocks)
    warnings = length(collect(eachmatch(r"(?m)^(?:Verifier warning|Warning) #\d+:", output)))
    summary = match(r"Trim verify finished with (\d+) errors?, (\d+) warnings?", output)
    if summary !== nothing
        reported = parse(Int, summary[1]) + parse(Int, summary[2])
        length(blocks) + warnings == reported || error("unrecognized trim verifier diagnostics:\n$output")
    end
    return length(blocks) - gaps, gaps, warnings
end

function test_trim_verifier_diagnostics()
    @testset "Trim verifier diagnostics" begin
        package_frame = "\nStacktrace:\n  [1] parse_value(...)\n    @ Postgres.API /tmp/Postgres/src/api/types.jl:1\n"
        stdlib_frame = "\nStacktrace:\n  [1] write(...)\n    @ Base64 /julia/share/julia/stdlib/v1.13/Base64/src/encode.jl:1\n"
        for prefix in ("Verifier error", "Error")
            output = "$prefix #1: unresolved call$package_frame\n$prefix #2: unresolved call$stdlib_frame\n$prefix #3: unresolved call$package_frame"
            @test _trim_verify_counts(output) == (2, 1, 0)
        end
        for prefix in ("Verifier warning", "Warning")
            @test _trim_verify_counts("$prefix #1: unresolved call") == (0, 0, 1)
        end
        @test _trim_verify_counts("Compiling...\n") == (0, 0, 0)
        @test _trim_verify_counts("Error #1: unresolved call$package_frame\nTrim verify finished with 1 error, 0 warnings.") == (1, 0, 0)
        @test_throws ErrorException _trim_verify_counts("Trim verify finished with 1 error, 0 warnings.")

        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        child = `$julia --startup-file=no -e $("print(stderr, repeat(\"x\", 65536)); flush(stderr)")`
        script = "print(stderr, \"start\\n\"); flush(stderr); run(pipeline($(repr(child)); stdout, stderr)); print(stderr, \"end\\n\"); flush(stderr)"
        code, output = _run_with_timeout(`$julia --startup-file=no -e $script`; timeout_s=30.0, label="capture test")
        @test code == 0
        @test output == "start\n" * repeat("x", 65536) * "end\n"
    end
end

function run_postgres_trim_compile_tests(cfg)::Nothing
    @testset "Trim compile" begin
        if Sys.iswindows() || Sys.WORD_SIZE != 64 || !_TRIM_SUPPORTED
            println("[trim] skipped: JuliaC trim compilation runs on 64-bit Linux/macOS with released Julia 1.12+")
            @test true
            return nothing
        end
        mktempdir() do tmpdir
            trim_project = joinpath(tmpdir, "trim_project")
            _prepare_trim_project(trim_project)
            julia = joinpath(Sys.BINDIR, Base.julia_exename())
            script = joinpath(@__DIR__, "postgres_trim_queries.jl")
            exe = joinpath(tmpdir, "postgres_trim_queries")
            # --output-exe takes a bare name, written to the working directory
            compile = Cmd(`$julia --startup-file=no --history-file=no --code-coverage=none --project=$trim_project -e $(_JULIAC_ENTRYPOINT_EXPR) -- --output-exe postgres_trim_queries --project=$trim_project --experimental --trim=unsafe-warn $script`; dir = tmpdir)
            exit_code, output = _run_with_timeout(compile; timeout_s = _TRIM_COMPILE_TIMEOUT_S, label = "compile")
            errors, stdlib_errors, warnings = _trim_verify_counts(output)
            println("[trim] verifier errors=$(errors) stdlib_errors=$(stdlib_errors) warnings=$(warnings)")
            (errors > 0 || warnings > 0 || exit_code != 0) && println(output)
            @test errors == 0
            @test warnings == 0
            @test exit_code == 0
            (errors == 0 && exit_code == 0) || return nothing
            # password auth would run SASLAuth's SCRAM exchange, one of the stdlib gaps
            if !(occursin("trust", DEFAULT_AUTH) || occursin("trust", DEFAULT_INITDB_ARGS))
                println("[trim] executable run skipped: needs trust auth")
                return nothing
            end
            env = copy(ENV)
            env["POSTGRES_TRIM_HOST"] = cfg.host
            env["POSTGRES_TRIM_PORT"] = string(cfg.port)
            env["POSTGRES_TRIM_USER"] = cfg.user
            env["POSTGRES_TRIM_PASSWORD"] = cfg.password
            env["POSTGRES_TRIM_DBNAME"] = cfg.dbname
            run_exit, run_output = _run_with_timeout(setenv(`$exe`, env); timeout_s = _TRIM_RUN_TIMEOUT_S, label = "run")
            run_exit == 0 || println(run_output)
            @test run_exit == 0
        end
    end
    return nothing
end
