# `Postgres.load!`: create a table from a Tables.jl source and stream its rows
# into it with `COPY ... FROM STDIN` (text format), all in one transaction.

# The column type `load!` declares for a Julia element type, `Missing` removed.
pgtype(::Type{Bool}) = "boolean"
pgtype(::Type{<:Union{Int8, Int16, UInt8}}) = "smallint"
pgtype(::Type{<:Union{Int32, UInt16}}) = "integer"
pgtype(::Type{<:Union{Int64, UInt32}}) = "bigint"
pgtype(::Type{<:Union{UInt64, Int128, UInt128, BigInt}}) = "numeric"
pgtype(::Type{<:Union{Float16, Float32}}) = "real"
pgtype(::Type{Float64}) = "double precision"
pgtype(::Type{<:AbstractVector{UInt8}}) = "bytea"
pgtype(::Type{Date}) = "date"
pgtype(::Type{Time}) = "time"
pgtype(::Type{DateTime}) = "timestamp(3)"
pgtype(::Type{Durations.Timestamp{Second}}) = "timestamp(0)"
pgtype(::Type{Durations.Timestamp{Millisecond}}) = "timestamp(3)"
pgtype(::Type{<:Durations.Timestamp}) = "timestamp"
pgtype(::Type{UUID}) = "uuid"
pgtype(::Type{<:API.IntervalType}) = "interval"
pgtype(::Type{<:DataDecimals.AbstractDecimal}) = "numeric"
pgtype(::Type{D}) where {D <: DataDecimals.Decimal} = "numeric($(precision(D)), $(DataDecimals.scale(D)))"
pgtype(::Type{<:AbstractVector{T}}) where {T} = string(coltype(T), "[]")
# Everything else is sent as its parameter text (`string(x)`).
pgtype(::Type) = "text"

coltype(T) = (D = nonmissingtype(T); D === Union{} ? "text" : pgtype(D))

# A COPY batch is sent once it reaches this many bytes; the rows of one load
# share one transaction, so batching only bounds the client's buffer.
const LOAD_BATCH_BYTES = 1 << 22

# COPY text format: `\N` is NULL; backslash, newline, carriage return and the
# tab delimiter are backslash-escaped. Values use the same text as parameters.
copyescape(b::UInt8) = b == UInt8('\\') ? UInt8('\\') : b == UInt8('\n') ? UInt8('n') :
                       b == UInt8('\r') ? UInt8('r') : b == UInt8('\t') ? UInt8('t') : 0x00

# Numbers print the same text as `_param` without building a String.
copytext!(io::IOBuffer, x::Union{Integer, AbstractFloat}) = print(io, x)

function copytext!(io::IOBuffer, x)
    text = _param(x)
    text === missing && return write(io, "\\N")
    bytes = codeunits(text)
    any(b -> copyescape(b) != 0x00, bytes) || return write(io, text)
    for b in bytes
        e = copyescape(b)
        e == 0x00 ? write(io, b) : write(io, UInt8('\\'), e)
    end
    return
end

function flushcopy!(conn::Connection, sql::String, buf::IOBuffer)
    seekstart(buf)
    copy_from(conn, sql, buf)
    truncate(buf, 0)
    return
end

"""
    Postgres.load!(table, conn, name; append=true, coltypes=Dict{Symbol,String}(), quoteidentifiers=true) -> String
    table |> Postgres.load!(conn, name; kw...)

Load a Tables.jl `table` into the PostgreSQL table `name` and return the table
name as used in SQL.

If the table does not exist, it is created with one column per source column,
typed from the source schema: integers as `smallint`/`integer`/`bigint`, floats
as `real`/`double precision`, `Bool` as `boolean`, `Date`, `Time`, `DateTime`
and `Timestamp`s as `date`/`time`/`timestamp`, `UUID` as `uuid`, decimals as
`numeric(P, S)`, byte vectors as `bytea`, other vectors as arrays, and
everything else as `text`. `coltypes` overrides the type of a column by name,
e.g. `coltypes=Dict(:payload => "jsonb")`. Columns are nullable. An existing
table keeps its definition; source columns are matched to its columns by name.

Rows are sent with `COPY ... FROM STDIN`. The whole load runs in one
transaction (a savepoint when one is already open): if any row fails, no rows
are added, and a table created by the call is removed. `append=false` deletes
the table's existing rows first.

Column names are always quoted. `quoteidentifiers=true` quotes `name` as one
identifier; pass `quoteidentifiers=false` to use `name` as written in SQL, for
example a schema-qualified `"analytics.events"`.
"""
function load! end

load!(conn::Connection, name::AbstractString; kw...) = table -> load!(table, conn, name; kw...)

function load!(table, conn::Connection, name::AbstractString; append::Bool=true,
               coltypes::AbstractDict=Dict{Symbol, String}(), quoteidentifiers::Bool=true)
    rows = Tables.rows(table)
    sch = Tables.schema(rows)
    if sch === nothing
        # the column types come from the schema, so materialize one
        rows = Tables.rows(Tables.columntable(rows))
        sch = Tables.schema(rows)
    end
    isempty(sch.names) && throw(ArgumentError("cannot load a table with no columns"))
    tbl = quoteidentifiers ? escape_identifier(String(name)) : String(name)
    columns = [escape_identifier(String(nm)) for nm in sch.names]
    copysql = string("COPY ", tbl, " (", join(columns, ", "), ") FROM STDIN")
    DBInterface.transaction(conn) do
        present = only(DBInterface.execute(conn, raw"SELECT to_regclass($1) IS NOT NULL AS present", (tbl,))).present
        if !present
            # a schema may leave its column types unknown (`nothing`)
            types = sch.types === nothing ? fill(Any, length(columns)) : sch.types
            defs = (string(columns[i], ' ', get(() -> coltype(types[i]), coltypes, sch.names[i]))
                    for i in eachindex(columns))
            DBInterface.execute(conn, string("CREATE TABLE ", tbl, " (", join(defs, ", "), ")"))
        end
        append || DBInterface.execute(conn, string("DELETE FROM ", tbl))
        copyrows!(conn, copysql, sch, rows)
    end
    return tbl
end

# A function barrier: `rows` and `sch` are concrete here, so each value is
# written without dynamic dispatch.
function copyrows!(conn::Connection, copysql::String, sch::Tables.Schema, rows)
    buf = IOBuffer()
    for row in rows
        Tables.eachcolumn(sch, row) do val, i, _
            i > 1 && write(buf, '\t')
            copytext!(buf, val)
        end
        write(buf, '\n')
        position(buf) >= LOAD_BATCH_BYTES && flushcopy!(conn, copysql, buf)
    end
    position(buf) > 0 && flushcopy!(conn, copysql, buf)
    return
end
