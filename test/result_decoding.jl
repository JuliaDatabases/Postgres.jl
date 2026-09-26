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

function decoding_values(row)
    values = Any[]
    StructUtils.applyeach(Postgres.PostgresStyle(), (name, value) -> push!(values, value), row)
    return values
end

struct DecodingStyle <: Postgres.AbstractPostgresStyle end
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
