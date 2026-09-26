# Run in an environment containing this checkout and BenchmarkTools. An
# optional port enables prepared-query measurements against a disposable
# local PostgreSQL server with a trust-authenticated postgres account:
# julia --project=/path/to/env benchmark/decoding.jl [port]
using Postgres, BenchmarkTools
using Postgres: DBInterface, StructUtils, Parsers, Tables
using Postgres.API: DataDecimals

const API = Postgres.API
const STYLE = Postgres.PostgresStyle()
const BENCH_ROW = NamedTuple{(:id, :small, :big, :ratio, :flag), Tuple{Int32, Int16, Int64, Float64, Bool}}

function wire_row(values, oids; names=[Symbol("c", i) for i in eachindex(values)])
    io = IOBuffer()
    write(io, hton(Int16(length(values))))
    for value in values
        if value === nothing
            write(io, hton(Int32(-1)))
        else
            write(io, hton(Int32(sizeof(value))), value)
        end
    end
    return API.DataRow(take!(io), names, oids, Dict(API.DEFAULT_TYPE_REGISTRY))
end

function untyped(row)
    data = Vector{Any}(undef, length(row.names))
    types = Type[Any for _ in row.names]
    StructUtils.applyeach(STYLE, Postgres.RowClosure(data, types, 1), row)
    return data
end
typed(row) = StructUtils.make(BENCH_ROW, row, STYLE)

function report(label, benchmark)
    trial = run(benchmark; samples=200, seconds=2)
    estimate = median(trial)
    times = sort(trial.times)
    println(label, " ns=", estimate.time, " bytes=", estimate.memory, " allocs=", estimate.allocs,
            " min_ns=", first(times), " p90_ns=", times[cld(9length(times), 10)], " max_ns=", last(times))
end

function main()
    println("Julia ", VERSION, " Postgres=", pathof(Postgres), " Parsers=", pkgversion(Parsers), " StructUtils=", pkgversion(StructUtils))
    row = wire_row(["123456", "-12345", "9223372036854775806", "12345.6789012345", "t"], [23,21,20,701,16]; names=collect(fieldnames(BENCH_ROW)))
    @assert typed(row) == (id=123456, small=-12345, big=9223372036854775806, ratio=12345.6789012345, flag=true)
    report("untyped_scalar_row", @benchmarkable untyped($row) evals=100)
    report("typed_scalar_row", @benchmarkable typed($row) evals=100)
    for (label, oid, value) in (("int64",20,"9223372036854775806"), ("float64",701,"12345.6789012345"), ("bool",16,"t"), ("numeric",1700,"123456789.0123400"), ("int_array",1007,"{1,2,3,4,5,6,7,8,9}"), ("json",3802,"{\"a\":123,\"b\":[1,2,3]}"))
        row = wire_row(fill(value, 16), fill(oid,16))
        report("untyped_16_"*label, @benchmarkable untyped($row) evals=100)
    end
    length(ARGS) == 0 && return
    conn = DBInterface.connect(Postgres.Connection,"127.0.0.1","postgres",nothing;dbname="postgres",port=parse(Int,ARGS[1]),sslmode="disable")
    try
        sql = "SELECT i::int4 AS id, (i % 30000)::int2 AS small, (i::int8 * 1000000000000)::int8 AS big, (i::float8 / 7) AS ratio, i % 2 = 0 AS flag FROM generate_series(1,10000) i"
        stmt = DBInterface.prepare(conn,sql)
        @assert length(DBInterface.execute(stmt)) == 10000
        @assert length(DBInterface.execute(stmt,nothing,Vector{BENCH_ROW})) == 10000
        report("live_untyped_10k", @benchmarkable DBInterface.execute($stmt) evals=1)
        report("live_typed_10k", @benchmarkable DBInterface.execute($stmt,nothing,Vector{BENCH_ROW}) evals=1)
        DBInterface.close!(stmt)
        dtype = NamedTuple{(:amount,), Tuple{API.PGDecimal}}
        stmt = DBInterface.prepare(conn, "SELECT (i::numeric / 100)::numeric(20,4) AS amount FROM generate_series(1,10000) i")
        @assert length(DBInterface.execute(stmt)) == 10000
        @assert length(DBInterface.execute(stmt,nothing,Vector{dtype})) == 10000
        report("live_untyped_decimal_10k", @benchmarkable DBInterface.execute($stmt) evals=1)
        report("live_typed_decimal_10k", @benchmarkable DBInterface.execute($stmt,nothing,Vector{$dtype}) evals=1)
        DBInterface.close!(stmt)
    finally
        DBInterface.close!(conn)
    end
end
main()
