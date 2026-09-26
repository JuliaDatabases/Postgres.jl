# Run against a disposable local PostgreSQL server, or the loopback counting
# proxy beside this file: julia --project benchmark/executemany.jl PORT [ROWS] [BYTES]
# Both variants use the same statement, parameters and driver in one process.
using Postgres
const DBI = Postgres.DBInterface

serial(stmt, params) = invoke(DBI.executemany, Tuple{DBI.Statement, Any}, stmt, params)
batched(stmt, params) = DBI.executemany(stmt, params)
middle(values) = sort(values)[cld(length(values), 2)]
cpu_seconds() = Sys.isunix() ? ccall(:clock, Clong, ()) / 1_000_000 : NaN

function sample(f, conn, stmt, params)
    DBI.execute(conn, "TRUNCATE executemany_benchmark")
    cpu = cpu_seconds()
    measured = @timed f(stmt, params)
    cpu = cpu_seconds() - cpu
    @assert measured.value === nothing
    nrows = length(first(params))
    row = only(DBI.execute(conn,
        "SELECT count(*) AS n, sum(id) AS total, sum(octet_length(value)) AS bytes FROM executemany_benchmark"))
    @assert row.n == nrows && row.total == nrows * (nrows + 1) ÷ 2
    @assert row.bytes == nrows * ncodeunits(params[2][1])
    return (wall=measured.time, cpu=cpu, bytes=measured.bytes,
            compilation=hasproperty(measured, :compile_time) ? measured.compile_time : NaN)
end

function main()
    port = parse(Int, ARGS[1])
    nrows = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 128
    payload = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 12
    conn = DBI.connect(Postgres.Connection, "127.0.0.1", "postgres", nothing;
        port, dbname="postgres", sslmode="disable", gssencmode="disable")
    try
        DBI.execute(conn, "CREATE TEMP TABLE executemany_benchmark(id int PRIMARY KEY, value text)")
        stmt = DBI.prepare(conn, raw"INSERT INTO executemany_benchmark VALUES ($1, $2)")
        params = (collect(1:nrows), fill(repeat("v", payload), nrows))
        for _ in 1:3, f in (serial, batched)
            sample(f, conn, stmt, params)
        end
        results = Dict(:serial => NamedTuple[], :batched => NamedTuple[])
        for trial in 1:9
            order = isodd(trial) ? (:serial, :batched) : (:batched, :serial)
            for variant in order
                result = sample(variant == :serial ? serial : batched, conn, stmt, params)
                push!(results[variant], result)
                println("sample=", trial, " variant=", variant, " ", result)
            end
        end
        println("Julia=", VERSION, " DBInterface=", pkgversion(DBI), " threads=", Threads.nthreads(),
                " rows=", nrows, " payload_bytes=", payload)
        for variant in (:serial, :batched)
            values = results[variant]
            wall = [x.wall * 1000 for x in values]
            println(variant, " wall_ms median=", middle(wall), " range=", extrema(wall),
                " client_cpu_ms=", middle([x.cpu * 1000 for x in values]),
                " allocated_bytes=", middle([x.bytes for x in values]),
                " compilation_s=", sum(x.compilation for x in values))
        end
        DBI.close!(stmt)
    finally
        DBI.close!(conn)
    end
end
main()
