const WireDecimal = DataDecimals.DecimalValue{DataDecimals.Int256}

function test_decimals()
    @testset "Numeric policy" begin
        @test !isdefined(Postgres, :Numeric)
        @test Postgres.ConnectionParams().numeric_overflow === :warn
        @test Postgres.parse_dsn("numeric_overflow=error").numeric_overflow === :error
        @test Postgres.parse_dsn("postgresql://localhost/db?numeric_overflow=error").numeric_overflow === :error
        @test_throws ArgumentError Postgres.ConnectionParams(numeric_overflow=:round)
        @test_throws ArgumentError Postgres.parse_dsn("numeric_overflow=round")
        @test_throws ArgumentError Postgres.Connection(numeric_overflow=:round)
        for text in ("NaN", "Infinity", "-Infinity", repeat("9", 80), repeat("1", 76) * ".0000")
            @test (@test_logs (:warn, r"cannot be represented exactly") Postgres.API.parse_numeric(text)) == text
            @test_throws Postgres.PostgresInterfaceError Postgres.API.parse_numeric(text, :error)
            @test_throws InexactError Postgres.API.parse_decimal(WireDecimal, text)
        end
        rng = MersenneTwister(0xdec256)
        for _ in 1:150
            digits = rand(rng, 78:180)
            text = string(rand(rng, ('-', '+')), rand(rng, '1':'9'), String(rand(rng, '0':'9', digits - 1)), ".0000")
            @test (@test_logs (:warn, r"cannot be represented exactly") Postgres.API.parse_numeric(text)) == text
            @test_throws Postgres.PostgresInterfaceError Postgres.API.parse_numeric(text, :error)
        end
    end
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
            value = @test_logs (:warn, r"cannot be represented exactly") Postgres.API.parse_numeric(string(coefficient))
            @test value isa String
            @test value == string(coefficient)
        end
        for text in (repeat("9", 80), repeat("1", 76) * ".0000", "0." * repeat("1", 100))
            value = @test_logs (:warn, r"cannot be represented exactly") Postgres.API.parse_numeric(text)
            @test value isa String
            @test string(value) == text
        end
        st = Postgres.PostgresStyle()
        @test first(StructUtils.lift(st, DataDecimals.Decimal64{2}, "1.2300")) == DataDecimals.Decimal64{2}("1.23")
        @test_throws InexactError StructUtils.lift(st, DataDecimals.Decimal64{2}, "1.234")
        @test_throws InexactError StructUtils.lift(st, DataDecimals.DecimalValue{Int64}, repeat("9", 30))
        @test_throws InexactError StructUtils.lift(st, WireDecimal, repeat("9", 80))
        @test Postgres.API.parse_array("{1.23,4.56}", DataDecimals.Decimal64{2}) == DataDecimals.Decimal64{2}.(["1.23", "4.56"])
        @test Postgres._param(DataDecimals.Decimal64{4}("1.2300")) == "1.2300"
    end
    @testset "Native decimal parsing preserves coefficient and scale" begin
        texts = ["0", "-0", "+0", "-0.0000", "+0.0000", "  +12.3400\t", "\u200312.3400\u2003",
                 ".5", "1.", "-.5", "+.5", "00012.3400", "0." * repeat("0", 100),
                 repeat("1", 76) * ".0000", "0." * repeat("0", 16382) * "1"]
        for n in 76:79
            push!(texts, repeat("1", n), "-" * repeat("1", n), "0." * repeat("1", n), "0." * repeat("0", n))
        end
        rng = MersenneTwister(0xdec0de)
        for _ in 1:200
            digits = String(rand(rng, '0':'9', rand(rng, 1:80)))
            split_at = rand(rng, 0:length(digits))
            push!(texts, string(rand(rng, ("", "+", "-")), digits[1:split_at], ".", digits[split_at+1:end]))
        end
        for text in texts
            # BigInt arithmetic is an independent oracle for the bounded
            # decimal scanner, including scale that trailing zeros preserve.
            stripped = strip(text)
            negative = startswith(stripped, "-")
            unsigned = (negative || startswith(stripped, "+")) ? stripped[2:end] : stripped
            parts = split(unsigned, '.'; limit=2)
            scale = length(parts) == 2 ? length(parts[2]) : 0
            coeff = parse(BigInt, join(parts)) * (negative ? -1 : 1)
            if typemin(DataDecimals.Int256) <= coeff <= typemax(DataDecimals.Int256) && scale <= 16383
                value = Postgres.API.parse_numeric(text, :error)
                @test value isa WireDecimal
                @test BigInt(DataDecimals.unscaled(value)) == coeff
                @test DataDecimals.scale(value) == scale
                typed = Postgres.API.parse_decimal(WireDecimal, text)
                @test BigInt(DataDecimals.unscaled(typed)) == coeff
                @test DataDecimals.scale(typed) == scale
            else
                @test_throws Postgres.PostgresInterfaceError Postgres.API.parse_numeric(text, :error)
                @test_throws InexactError Postgres.API.parse_decimal(WireDecimal, text)
            end
            T = DataDecimals.Decimal64{2}
            expected = try
                T(coeff // big(10)^scale)
            catch err
                err
            end
            if expected isa Exception
                @test_throws typeof(expected) Postgres.API.parse_decimal(T, text)
            else
                @test Postgres.API.parse_decimal(T, text) === expected
            end
        end
        for text in ("", " ", "+", "-", ".", "1..2", "1,2", "1/2", "1x", "1\0", "1.2.3", "1e", "1e+")
            @test_throws Exception Postgres.API.parse_numeric(text, :error)
            @test_throws Exception Postgres.API.parse_decimal(WireDecimal, text)
        end
        for text in ("0e100001", "0e-100001", "1e100001", "1e-100001")
            @test_throws Postgres.PostgresInterfaceError Postgres.API.parse_numeric(text, :error)
            @test_throws Postgres.PostgresInterfaceError Postgres.API.parse_decimal(WireDecimal, text)
        end
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
        wide = repeat("9", 80)
        row = only(DBInterface.execute(conn, raw"SELECT $1::numeric[] AS values, numrange(1.23, $2, '[)') AS span", ([WireDecimal(123, 2), missing, wide], wide)))
        @test row.values[1] == WireDecimal(123, 2)
        @test ismissing(row.values[2])
        @test row.values[3] == wide
        @test row.span.lower == WireDecimal(123, 2)
        @test row.span.upper == wide
        fixed = DataDecimals.Decimal64{2}("12.34")
        @test DBInterface.execute(conn, raw"SELECT $1::numeric AS value", (fixed,), NamedTuple{(:value,), Tuple{typeof(fixed)}}).value == fixed
        @test DBInterface.execute(conn, raw"SELECT $1::numeric[] AS value", ([fixed],), NamedTuple{(:value,), Tuple{Vector{typeof(fixed)}}}).value == [fixed]
        @test_throws InexactError DBInterface.execute(conn, "SELECT 1.234::numeric AS value", (), NamedTuple{(:value,), Tuple{typeof(fixed)}})
        @test only(DBInterface.execute(conn, "SELECT 1 AS value")).value == 1
    end
end

function test_numeric_policy_roundtrips(conn)
    @testset "Numeric overflow policy round trips" begin
        wide = repeat("9", 80)
        cases = ((raw"SELECT $1::numeric AS value", (wide,)),
                 (raw"SELECT ARRAY[1.23, $1::numeric, NULL] AS value", (wide,)),
                 (raw"SELECT numrange(1.23, $1::numeric, '[)') AS value", (wide,)),
                 ("SELECT 'NaN'::numeric AS value", ()))
        for (sql, params) in cases
            @test_logs (:warn, r"cannot be represented exactly") DBInterface.execute(conn, sql, params)
        end
        params = Postgres.ConnectionParams(host=conn.host, port=conn.port, user=conn.user,
            password=conn.password, dbname=conn.dbname, sslmode="disable", numeric_overflow=:error)
        DBInterface.connect(Postgres.Connection, params) do strict
            for (sql, args) in cases
                @test_throws Postgres.PostgresInterfaceError DBInterface.execute(strict, sql, args)
                @test only(DBInterface.execute(strict, "SELECT 42 AS value")).value == 42
            end
            @test only(DBInterface.execute(strict, raw"SELECT $1::numeric::text AS value", (wide,))).value == wide
            @test_throws InexactError DBInterface.execute(strict, raw"SELECT $1::numeric AS value", (wide,), NamedTuple{(:value,), Tuple{WireDecimal}})
            @test only(DBInterface.execute(strict, "SELECT 42 AS value")).value == 42
        end
        DBInterface.connect(Postgres.Connection, params; numeric_overflow=:warn) do permissive
            @test (@test_logs (:warn, r"cannot be represented exactly") only(DBInterface.execute(permissive, raw"SELECT $1::numeric AS value", (wide,)))).value == wide
            @test_throws InexactError DBInterface.execute(permissive, raw"SELECT $1::numeric AS value", (wide,), NamedTuple{(:value,), Tuple{WireDecimal}})
            @test_throws InexactError DBInterface.execute(permissive, raw"SELECT ARRAY[$1::numeric] AS value", (wide,), NamedTuple{(:value,), Tuple{Vector{WireDecimal}}})
        end
        pool = Postgres.ConnectionPool(params; limit=1)
        try
            Postgres.with_connection(pool) do strict
                @test_throws Postgres.PostgresInterfaceError DBInterface.execute(strict, raw"SELECT $1::numeric AS value", (wide,))
                @test only(DBInterface.execute(strict, "SELECT 42 AS value")).value == 42
            end
        finally
            DBInterface.close!(pool)
        end
        # PostgreSQL's largest integral numeric must survive the text fallback.
        huge = repeat("9", 131072)
        @test (@test_logs (:warn, r"cannot be represented exactly") only(DBInterface.execute(conn, raw"SELECT $1::numeric AS value", (huge,)))).value == huge
    end
end
