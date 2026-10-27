function decoding_row(values, oids; names=[Symbol("c", i) for i in eachindex(values)])
    io = IOBuffer()
    write(io, hton(Int16(length(values))))
    for value in values
        if value === nothing
            write(io, hton(Int32(-1)))
        else
            write(io, hton(Int32(sizeof(value))), value)
        end
    end
    return Postgres.API.DataRow(take!(io), names, oids, Dict(Postgres.API.DEFAULT_TYPE_REGISTRY))
end

function test_typed_read_compatibility(conn)
    @testset "Typed read compatibility on PostgreSQL" begin
        settings = ("SET LOCAL TimeZone = 'UTC'", "SET LOCAL TimeZone = 'Asia/Kolkata'",
                    "SET LOCAL TimeZone = 'America/New_York'", "SET LOCAL IntervalStyle = 'iso_8601'",
                    "SET LOCAL bytea_output = 'escape'", "SET LOCAL extra_float_digits = 0",
                    "SET LOCAL extra_float_digits = 3")
        for setting in settings
            DBInterface.transaction(conn) do
                DBInterface.execute(conn, "SET LOCAL DateStyle = 'ISO, YMD'")
                DBInterface.execute(conn, setting)
                for pgtype in ("float4", "float8")
                    sql = "SELECT 1e15::$pgtype AS value"
                    decoded = only(DBInterface.execute(conn, sql)).value
                    for T in (Int64, Union{Nothing, Int64}, Union{Missing, Int64})
                        @test DBInterface.execute(conn, sql, (), NamedTuple{(:value,), Tuple{T}}).value === Int64(decoded)
                    end
                    for value in ("3.5", "1e19", "'NaN'", "'Infinity'")
                        @test_throws InexactError DBInterface.execute(conn, "SELECT $value::$pgtype AS value", (), NamedTuple{(:value,), Tuple{Int64}})
                    end
                    @test DBInterface.execute(conn, "SELECT ARRAY[1e15::$pgtype, -1e15::$pgtype] AS value", (),
                        NamedTuple{(:value,), Tuple{Vector{Int64}}}).value == [Int64(decoded), -Int64(decoded)]
                end
                widened = DBInterface.execute(conn, "SELECT 0.1::float4 AS value", (), NamedTuple{(:value,), Tuple{Float64}}).value
                @test widened === Float64(0.1f0)
                for (expr, T, expected) in (("42::int8", Union{Int64, String}, Int64(42)),
                                          ("'42'::text", Union{Int64, String}, "42"),
                                          ("1.5::float8", Union{Int64, Float64}, 1.5),
                                          ("NULL::float8", Union{Missing, Int64, Float64}, missing),
                                          ("'null'::json", Union{Nothing, String}, "null"),
                                          ("NULL::jsonb", Union{Nothing, String}, nothing))
                    @test DBInterface.execute(conn, "SELECT $expr AS value", (), NamedTuple{(:value,), Tuple{T}}).value === expected
                end
                # The old date forces named zones to emit historical second offsets.
                for expr in ("'1800-01-01 00:00:00.123456'::timestamp", "'1800-01-01 00:00:00.123456+00'::timestamptz")
                    expected = Time(0, 0, 0, 123, 456)
                    for T in (Time, Union{Nothing, Time}, Union{Missing, Time})
                        @test DBInterface.execute(conn, "SELECT $expr AS value", (), NamedTuple{(:value,), Tuple{T}}).value === expected
                    end
                    @test DBInterface.execute(conn, "SELECT ARRAY[$expr] AS value", (), NamedTuple{(:value,), Tuple{Vector{Time}}}).value == [expected]
                    @test isequal(DBInterface.execute(conn, "SELECT ARRAY[$expr, NULL] AS value", (),
                        NamedTuple{(:value,), Tuple{Vector{Union{Missing, Time}}}}).value, [expected, missing])
                end
                for (expr, expected) in (("9223372036854775807.00::numeric", typemax(Int64)),
                                         ("-9223372036854775808.00::numeric", typemin(Int64)))
                    @test DBInterface.execute(conn, "SELECT $expr AS value", (), NamedTuple{(:value,), Tuple{Int64}}).value === expected
                end
                @test_throws InexactError DBInterface.execute(conn, "SELECT 9223372036854775808::numeric AS value", (), NamedTuple{(:value,), Tuple{Int64}})
                @test_throws ArgumentError DBInterface.execute(conn, "SELECT 9007199254740993.5::numeric AS value", (), NamedTuple{(:value,), Tuple{Int64}})
            end
        end
    end
end

function decoding_values(row)
    values = Any[]
    StructUtils.applyeach(Postgres.PostgresStyle(), (name, value) -> push!(values, value), row)
    return values
end

decoding_field(::Type{T}, text, oid) where {T} = StructUtils.make(
    NamedTuple{(:value,), Tuple{T}}, decoding_row([text], [oid]; names=[:value]), Postgres.PostgresStyle()).value

struct DecodingStyle <: Postgres.AbstractPostgresStyle end

@enum DecodingColor decoding_red decoding_green

struct StringFields
    json::String
    jsonb::String
    int::String
    id::String
    at::Union{Nothing, String}
    amount::Union{Missing, String}
    tags::String
    note::Union{Nothing, String}
end
StructUtils.lift(::DecodingStyle, ::Type{Int64}, value::Int32) = Int64(value) + 1, nothing

function test_result_decoding()
    @testset "Bounded scalar decoding" begin
        cases = ((21, Int16, ["-32768", "32767", "0", "+12", " 12 "]),
                 (23, Int32, ["-2147483648", "2147483647", "-0", "42"]),
                 (20, Int64, ["-9223372036854775808", "9223372036854775807", "0", "42"]),
                 (26, Cuint, ["0", "4294967295", "42"]),
                 (700, Float32, ["1.5", "-0.0", "NaN", "Infinity", "-Infinity", "1.1754944e-38"]),
                 (701, Float64, ["1.5", "-0.0", "NaN", "Infinity", "-Infinity", "5e-324", "1.7976931348623157e308"]))
        for (oid, T, texts) in cases, text in texts
            # Surround the field with other cells: a decoder must respect both
            # ends of its span, including values ending in an exponent or sign.
            row = decoding_row(["prefix α", text, "suffix"], [25, oid, 25]; names=[:before, :value, :after])
            expected = parse(T, text)
            @test isequal(decoding_values(row), ["prefix α", expected, "suffix"])
            target = NamedTuple{(:before, :value, :after), Tuple{String, T, String}}
            typed = StructUtils.make(target, row, Postgres.PostgresStyle())
            @test typed.value isa T
            @test isequal(typed.value, expected)
            @test typed.before == "prefix α" && typed.after == "suffix"
        end
        for (text, expected) in (("t", true), ("f", false), ("1", true), ("0", false))
            @test only(decoding_values(decoding_row([text], [16]))) === expected
        end
        for text in ("", "10", "true", "α")
            @test_throws Postgres.PostgresInterfaceError decoding_values(decoding_row([text], [16]))
        end
        for text in ("", "1e", "+", "12x", "9223372036854775808")
            row = decoding_row([text, "12"], [20, 20])
            expected_error = try
                Postgres.Parsers.parse(Int64, text)
            catch err
                typeof(err)
            end
            @test expected_error <: Exception
            @test_throws expected_error decoding_values(row)
        end
        @test isequal(decoding_values(decoding_row(["", nothing, ""], [25, 23, 25])), ["", nothing, ""])

        row = decoding_row(["41"], [23]; names=[:value])
        target = NamedTuple{(:value,), Tuple{Int64}}
        @test StructUtils.make(target, row, DecodingStyle()).value === Int64(42)
        Postgres.API.register_type!(row.type_registry, 23, Int64; parser=(text::String, registry) -> parse(Int64, text) + 100)
        @test only(decoding_values(row)) === Int64(141)
        @test StructUtils.make(target, row, Postgres.PostgresStyle()).value === Int64(141)
    end

    @testset "Registered temporal types without custom parsers" begin
        cases = ((1114, Postgres.API.PGTimestamp, "2024-01-02 03:04:05.123456", Durations.Timestamp{Microsecond}(2024, 1, 2, 3, 4, 5, 123, 456)),
                 (1184, Postgres.API.PGTimestamp, "2024-01-02 03:04:05.123456+02:30", Durations.Timestamp{Microsecond}(2024, 1, 2, 0, 34, 5, 123, 456)),
                 (1114, DateTime, "2024-01-02 03:04:05.123", DateTime(2024, 1, 2, 3, 4, 5, 123)),
                 (1184, DateTime, "2024-01-02 03:04:05.123+02:30", DateTime(2024, 1, 2, 0, 34, 5, 123)))
        for (oid, T, text, expected) in cases
            row = decoding_row(["prefix", text, "suffix"], [25, oid, 25]; names=[:before, :value, :after])
            Postgres.API.register_type!(row.type_registry, oid, T)
            @test decoding_values(row) == ["prefix", expected, "suffix"]
            # An Any field must still use the registered decoder, including
            # timezone conversion and the chosen timestamp resolution.
            target = NamedTuple{(:before, :value, :after), Tuple{String, Any, String}}
            @test StructUtils.make(target, row, Postgres.PostgresStyle()).value === expected
        end
    end

    @testset "String fields take the column text" begin
        texts = ["{\"a\": [1, 2]}", "{\"a\": [1, 2]}", "42", "c8b1cf79-de6a-54ab-a142-682c06a0de6a",
                 "2024-01-02 03:04:05.123+02:30", "12.50", "{a,b}", nothing]
        row = decoding_row(texts, [114, 3802, 23, 2950, 1184, 1700, 1009, 25]; names=collect(fieldnames(StringFields)))
        @test StructUtils.make(StringFields, row, Postgres.PostgresStyle()) == StringFields(texts[1:7]..., nothing)
        target = NamedTuple{(:json, :jsonb), Tuple{String, JSONType}}
        typed = StructUtils.make(target, decoding_row(texts[1:2], [114, 3802]; names=[:json, :jsonb]), Postgres.PostgresStyle())
        @test typed.json == texts[1]
        @test JSON.parse(typed.jsonb)["a"] == [1, 2]
        # untyped results keep the OID decoders
        values = decoding_values(row)
        @test values[2] isa JSONType && values[3] === Int32(42) && values[7] == ["a", "b"]
        # a custom parser registered for a String column still applies
        row = decoding_row(["abc"], [999_999]; names=[:value])
        Postgres.API.register_type!(row.type_registry, 999_999, String; parser=(text::String, registry) -> uppercase(text))
        @test StructUtils.make(NamedTuple{(:value,), Tuple{String}}, row, Postgres.PostgresStyle()).value == "ABC"
    end

    @testset "Typed fields decode the column text" begin
        # values the OID decoders converted exactly before still convert
        texts = ["12.00", "7.0", "2024-01-02 23:30:00-05", "{12.00,3}", "5", "decoding_red"]
        names = [:total, :count, :day, :amounts, :maybe, :color]
        row = decoding_row(texts, [1700, 1700, 1184, 1231, 20, 25]; names=names)
        target = NamedTuple{Tuple(names), Tuple{Int64, Int32, Date, Vector{Int64}, Union{Nothing, Int64}, DecodingColor}}
        typed = StructUtils.make(target, row, Postgres.PostgresStyle())
        @test typed == (total=12, count=Int32(7), day=Date(2024, 1, 3), amounts=[12, 3], maybe=5, color=decoding_red)
        @test_throws ArgumentError StructUtils.make(NamedTuple{(:total,), Tuple{Int64}},
            decoding_row(["12.50"], [1700]; names=[:total]), Postgres.PostgresStyle())
        # a registered decoder applies when it produces the field's type;
        # otherwise the field decodes the text by its declared type
        row = decoding_row(["decoding_red", "decoding_red"], [999_998, 999_998]; names=[:symbol, :color])
        Postgres.API.register_type!(row.type_registry, 999_998, Symbol; parser=(text::String, registry) -> Symbol(text))
        typed = StructUtils.make(NamedTuple{(:symbol, :color), Tuple{Symbol, DecodingColor}}, row, Postgres.PostgresStyle())
        @test typed == (symbol=:decoding_red, color=decoding_red)
    end

    @testset "Floating columns retain their precision in typed conversions" begin
        for (oid, array_oid, F) in ((700, 1021, Float32), (701, 1022, Float64))
            for text in ("1e+15", "-1e+15", "1e+18", "-1e+18", "9.223371e18", "-9.223372e18"), T in (Int64, Union{Nothing, Int64}, Union{Missing, Int64})
                @test decoding_field(T, text, oid) === Int64(parse(F, text))
            end
            for text in ("3.5", "1e-2", "1e+19", "-1e+19", "NaN", "Infinity", "-Infinity")
                @test_throws InexactError decoding_field(Int64, text, oid)
                @test_throws InexactError decoding_field(Vector{Int64}, "{$text}", array_oid)
            end
            @test decoding_field(Int8, "1e+2", oid) === Int8(100)
            @test_throws InexactError decoding_field(Int8, "1.28e+2", oid)
            @test decoding_field(Cuint, "1e+2", oid) === Cuint(100)
            @test_throws InexactError decoding_field(Cuint, "-1e+2", oid)
            for T in (Vector{Int64}, Union{Nothing, Vector{Int64}}, Union{Missing, Vector{Int64}})
                @test decoding_field(T, "{1e+15,-1e+15}", array_oid) == Int64[parse(F, "1e+15"), parse(F, "-1e+15")]
            end
        end
        @test decoding_field(Float64, "0.1", 700) === Float64(0.1f0)
        @test decoding_field(Vector{Float64}, "{0.1}", 1021) == [Float64(0.1f0)]
        @test decoding_field(Int64, "9223372036854775807.00", 1700) === typemax(Int64)
        @test decoding_field(Int64, "-9223372036854775808.00", 1700) === typemin(Int64)
        @test_throws InexactError decoding_field(Int64, "9223372036854775808.00", 1700)
        @test_throws ArgumentError decoding_field(Int64, "9007199254740993.5", 1700)
        # Exponent-form text is not a floating column and must not round through Float64.
        @test_throws ArgumentError decoding_field(Int64, "9007199254740993e0", 25)
        for (T, expected) in ((Union{Nothing, Int64}, nothing), (Union{Missing, Int64}, missing),
                              (Union{Nothing, Vector{Int64}}, nothing), (Union{Missing, Vector{Int64}}, missing))
            @test decoding_field(T, nothing, 701) === expected
        end
        row = decoding_row(["1e+15"], [701]; names=[:value])
        Postgres.API.register_type!(row.type_registry, 701, Int64; parser=(text::String, registry) -> Int64(42))
        @test StructUtils.make(NamedTuple{(:value,), Tuple{Int64}}, row, Postgres.PostgresStyle()).value === Int64(42)
    end

    @testset "General unions retain the decoded column type" begin
        for T in (Union{Int64, Float64}, Union{Nothing, Int64, Float64}, Union{Missing, Int64, Float64})
            @test decoding_field(T, "1.5", 701) === 1.5
            @test decoding_field(T, "42", 20) === Int64(42)
        end
        for T in (Union{Int64, String}, Union{Nothing, Int64, String}, Union{Missing, Int64, String})
            @test decoding_field(T, "42", 20) === Int64(42)
            @test decoding_field(T, "42", 25) === "42"
        end
        @test decoding_field(Union{Nothing, Int64, String}, nothing, 20) === nothing
        @test decoding_field(Union{Missing, Int64, Float64}, nothing, 701) === missing
        @test decoding_field(Vector{Union{Int64, String}}, "{42}", 1016) == Int64[42]
        @test isequal(decoding_field(Vector{Union{Missing, Int64, Float64}}, "{1.5,NULL}", 1022), [1.5, missing])
        # IntervalType is an intentional union with its own text lift.
        @test decoding_field(Postgres.API.IntervalType, "1 year 2 mons", 1186) == Year(1) + Month(2)
    end

    @testset "Timestamp columns into Time fields" begin
        expected = Time(23, 59, 59, 999, 999)
        for (oid, array_oid, text) in ((1114, 1115, "1969-12-31 23:59:59.999999"),
                                      (1184, 1185, "1970-01-01 05:21:09.999999+05:21:10"),
                                      (1184, 1185, "1969-12-31 18:38:49.999999-05:21:10"))
            for T in (Time, Union{Nothing, Time}, Union{Missing, Time})
                @test decoding_field(T, text, oid) === expected
            end
            for T in (Vector{Time}, Union{Nothing, Vector{Time}}, Union{Missing, Vector{Time}})
                @test decoding_field(T, "{\"$text\"}", array_oid) == [expected]
            end
        end
        @test decoding_field(Time, "03:04:05.123456789", 1083) === Time(3, 4, 5, 123, 456, 789)
        @test decoding_field(Union{Nothing, Time}, nothing, 1114) === nothing
        @test decoding_field(Union{Missing, Time}, nothing, 1184) === missing
        @test decoding_field(Union{Nothing, Vector{Time}}, nothing, 1185) === nothing
        @test_throws Postgres.PostgresInterfaceError decoding_field(Time, "infinity", 1114)
        @test_throws Postgres.PostgresInterfaceError decoding_field(Time, "0001-01-01 00:00:00 BC", 1114)
    end

    @testset "JSON null stays distinct from SQL NULL in text fields" begin
        for oid in (114, 3802)
            @test decoding_field(Union{Nothing, String}, "null", oid) === "null"
            @test decoding_field(Union{Missing, String}, "null", oid) === "null"
            @test decoding_field(Union{Nothing, String}, nothing, oid) === nothing
            @test decoding_field(Union{Missing, String}, nothing, oid) === missing
        end
    end

    @testset "Date and DateTime parameters" begin
        for x in (Date(2024, 1, 2), Date(12345, 1, 2), Date(-5, 1, 2), DateTime(2024, 1, 2, 3, 4, 5),
                  DateTime(2024, 1, 2, 3, 4, 5, 7), DateTime(2024, 1, 2, 3, 4, 5, 120), DateTime(-44, 3, 15, 12))
            @test Postgres._param(x) == string(x)
        end
    end

    @testset "Protocol strings reject NUL bytes" begin
        @test_throws Postgres.PostgresInterfaceError Postgres.API.writepart(IOBuffer(), "a\0b")
        @test_throws Postgres.PostgresInterfaceError Postgres.API.writepart(IOBuffer(), ("key", "a\0b"))
    end

    @testset "Decoded values own retained text" begin
        row = decoding_row(["hello α🙂", "{\"value\":\"saved α\"}", "custom β", "{first,second}", raw"\x0001ff"],
                           [25, 3802, 999_999, 1009, 17])
        Postgres.API.register_type!(row.type_registry, 999_999, String; parser=(text::String, registry) -> text)
        values = decoding_values(row)
        # Result rows, custom parser values, and lazy JSON may outlive the
        # buffered message and every later query on the connection.
        fill!(row.buf, 0xff)
        GC.gc()
        @test values[1] == "hello α🙂"
        @test JSON.parse(values[2])["value"] == "saved α"
        @test values[3] == "custom β"
        @test values[4] == ["first", "second"]
        @test values[5] == [0x00, 0x01, 0xff]

        row = decoding_row(["hello α🙂", "{\"value\":\"saved β\"}", ""], [25, 3802, 25]; names=[:text, :json, :empty])
        target = NamedTuple{(:text, :json, :empty), Tuple{String, JSONType, String}}
        values = StructUtils.make(target, row, Postgres.PostgresStyle())
        fill!(row.buf, 0xff)
        GC.gc()
        @test values.text == "hello α🙂"
        @test JSON.parse(values.json)["value"] == "saved β"
        @test values.empty == ""
    end
end
