const WireDecimal = DataDecimals.DecimalValue{DataDecimals.Int256}

function test_decimals()
    @testset "Exact shared decimals" begin
        for text in ("0", "-0.00120", "123.4500", repeat("9", 76), "0." * repeat("0", 16382) * "1")
            value = Postgres.API.parse_numeric(text)
            @test value isa WireDecimal
            @test string(value) == text
        end
        for coefficient in (BigInt(typemin(DataDecimals.Int256)), BigInt(typemax(DataDecimals.Int256)))
            @test Postgres.API.parse_numeric(string(coefficient)) isa WireDecimal
        end
        # Crossing the storage boundary must preserve the full coefficient.
        for coefficient in (BigInt(typemin(DataDecimals.Int256)) - 1, BigInt(typemax(DataDecimals.Int256)) + 1)
            value = Postgres.API.parse_numeric(string(coefficient))
            @test value isa Postgres.Numeric
            @test value.coeff == coefficient
        end
        for text in (repeat("9", 80), repeat("1", 76) * ".0000", "0." * repeat("1", 100))
            value = Postgres.API.parse_numeric(text)
            @test value isa Postgres.Numeric
            @test string(value) == text
        end
        st = Postgres.PostgresStyle()
        @test first(StructUtils.lift(st, DataDecimals.Decimal64{2}, "1.2300")) == DataDecimals.Decimal64{2}("1.23")
        @test_throws InexactError StructUtils.lift(st, DataDecimals.Decimal64{2}, "1.234")
        @test_throws InexactError StructUtils.lift(st, DataDecimals.DecimalValue{Int64}, repeat("9", 30))
        @test first(StructUtils.lift(st, Postgres.Numeric, "1.2300")) == Postgres.Numeric(BigInt(12300), 4)
        @test Postgres.API.parse_array("{1.23,4.56}", DataDecimals.Decimal64{2}) == DataDecimals.Decimal64{2}.(["1.23", "4.56"])
        @test Postgres._param(DataDecimals.Decimal64{4}("1.2300")) == "1.2300"
    end
end

function test_decimal_roundtrips(conn)
    @testset "Decimal server round trips" begin
        rng = MersenneTwister(0xdec1aa1)
        for _ in 1:100
            scale = rand(rng, 0:30)
            coefficient = rand(rng, Int128) ÷ 10
            value = WireDecimal(coefficient, scale)
            row = only(DBInterface.execute(conn, raw"SELECT $1::numeric AS value, scale($1::numeric) AS scale", (value,)))
            @test row.value isa WireDecimal
            @test row.value == value
            @test DataDecimals.scale(row.value) == scale == row.scale
            @test DBInterface.execute(conn, raw"SELECT $1::numeric AS value", (value,), NamedTuple{(:value,), Tuple{WireDecimal}}).value == value
            @test isequal(only(DBInterface.execute(conn, raw"SELECT $1::numeric[] AS value", ([value, missing],))).value, [value, missing])
        end
        for text in (repeat("9", 80), repeat("1", 76) * ".0000", "0." * repeat("0", 16382) * "1")
            row = only(DBInterface.execute(conn, raw"SELECT $1::numeric AS value, scale($1::numeric) AS scale", (text,)))
            @test string(row.value) == text
            @test string(only(DBInterface.execute(conn, raw"SELECT $1::numeric AS value", (row.value,))).value) == text
        end
        wide = Postgres.Numeric(parse(BigInt, repeat("9", 80)), 0)
        row = only(DBInterface.execute(conn, raw"SELECT $1::numeric[] AS values, numrange(1.23, $2, '[)') AS span", ([WireDecimal(123, 2), missing, wide], wide)))
        @test row.values[1] == WireDecimal(123, 2)
        @test ismissing(row.values[2])
        @test row.values[3] == wide
        @test row.span.lower == WireDecimal(123, 2)
        @test row.span.upper == wide
        @test DBInterface.execute(conn, "SELECT 1.2300::numeric AS value", (), NamedTuple{(:value,), Tuple{Postgres.Numeric}}).value == Postgres.Numeric(BigInt(12300), 4)
        fixed = DataDecimals.Decimal64{2}("12.34")
        @test DBInterface.execute(conn, raw"SELECT $1::numeric AS value", (fixed,), NamedTuple{(:value,), Tuple{typeof(fixed)}}).value == fixed
        @test DBInterface.execute(conn, raw"SELECT $1::numeric[] AS value", ([fixed],), NamedTuple{(:value,), Tuple{Vector{typeof(fixed)}}}).value == [fixed]
        @test_throws InexactError DBInterface.execute(conn, "SELECT 1.234::numeric AS value", (), NamedTuple{(:value,), Tuple{typeof(fixed)}})
        @test only(DBInterface.execute(conn, "SELECT 1 AS value")).value == 1
    end
end
