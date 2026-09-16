const MicroTimestamp = Durations.Timestamp{Microsecond}

function test_timestamps()
    @testset "Timestamp precision and bounds" begin
        registry = copy(Postgres.API.DEFAULT_TYPE_REGISTRY)
        expected = MicroTimestamp(1969, 12, 31, 23, 59, 59, 999, 999)
        @test Dates.value(expected) == -1
        for oid in (1114, 1184)
            @test Postgres.API.parse_value(oid, "1969-12-31 23:59:59.999999", registry) === expected
        end
        @test Postgres.API.pg_parse_timestamp("1970-01-01 05:21:09.999999+05:21:10") === expected
        @test Postgres.API.pg_parse_timestamp("1969-12-31 18:38:49.999999-05:21:10") === expected
        for value in (MicroTimestamp(1), MicroTimestamp(10000), typemax(MicroTimestamp))
            @test Postgres.API.pg_parse_timestamp(string(value)) === value
        end
        @test_throws Postgres.PostgresInterfaceError Postgres.API.pg_parse_timestamp("294276-12-31 23:59:59.999999")
        @test_throws Postgres.PostgresInterfaceError Postgres.API.pg_parse_timestamp(string(typemax(MicroTimestamp), "-00:00:01"))
        @test_throws InexactError Postgres._param(Durations.Timestamp{Nanosecond}(1970) + Nanosecond(1))
        @test Postgres._param(Durations.Timestamp{Nanosecond}(1970) + Nanosecond(1000)) == "1970-01-01T00:00:00.000001Z"
        @test_throws Postgres.PostgresInterfaceError Postgres._param(MicroTimestamp(0))
        @test_throws InexactError StructUtils.lift(Postgres.PostgresStyle(), Durations.Timestamp{Millisecond}, "1970-01-01 00:00:00.000001")
        wide = Durations.Timestamp{Second}(294276, 12, 31, 23, 59, 59)
        @test first(StructUtils.lift(Postgres.PostgresStyle(), typeof(wide), "294276-12-31 23:59:59")) === wide
        @test Postgres.API.parse_array("{\"294276-12-31 23:59:59\"}", typeof(wide)) == [wide]
        @test first(StructUtils.lift(Postgres.PostgresStyle(), Durations.Timestamp{Nanosecond}, "1970-01-01 00:00:00.000001")) === Durations.Timestamp{Nanosecond}(1970) + Nanosecond(1000)
        # Explicit DateTime targets retain their historical millisecond floor.
        @test first(StructUtils.lift(Postgres.PostgresStyle(), DateTime, "1969-12-31 23:59:59.999999")) == DateTime(1969, 12, 31, 23, 59, 59, 999)
        @test Postgres.API.parse_array("{\"1969-12-31 23:59:59.999999\"}", MicroTimestamp) == [expected]
    end
end

function test_timestamp_roundtrips(conn)
    DBInterface.execute(conn, "SET TimeZone = 'Asia/Kolkata'")
    try
        _test_timestamp_roundtrips(conn)
    finally
        DBInterface.execute(conn, "RESET TimeZone")
    end
end

function _test_timestamp_roundtrips(conn)
    @testset "Timestamp server round trips" begin
        rng = MersenneTwister(0x7157a)
        for ticks in [Int64(-1), 0, 1, rand(rng, -62_135_596_800_000_000:253_402_300_799_999_999, 100)...]
            value = MicroTimestamp(Dates.UTInstant(Microsecond(ticks)))
            for sql in (raw"SELECT $1::timestamp AS value", raw"SELECT $1::timestamptz AS value")
                @test only(DBInterface.execute(conn, sql, (value,))).value === value
                @test DBInterface.execute(conn, sql, (value,), NamedTuple{(:value,), Tuple{MicroTimestamp}}).value === value
            end
            @test isequal(only(DBInterface.execute(conn, raw"SELECT $1::timestamp[] AS value", ([value, missing],))).value, [value, missing])
            range = only(DBInterface.execute(conn, raw"SELECT tstzrange($1, $2, '[)') AS value", (value, value + Microsecond(1)))).value
            @test range isa Postgres.PostgresRange{MicroTimestamp}
            @test range.lower === value
            @test range.upper === value + Microsecond(1)
        end
        @test only(DBInterface.execute(conn, raw"SELECT $1::timestamp AS value", (typemax(MicroTimestamp),))).value === typemax(MicroTimestamp)
        @test_throws InexactError DBInterface.execute(conn, raw"SELECT $1::timestamp AS value", (Durations.Timestamp{Nanosecond}(1970) + Nanosecond(1),))
        wide = DBInterface.execute(conn, "SELECT '294276-12-31 23:59:59'::timestamp AS value", (), NamedTuple{(:value,), Tuple{Durations.Timestamp{Second}}})
        @test DBInterface.execute(conn, "SELECT 42 AS value", (), NamedTuple{(:value,), Tuple{Any}}).value === Int32(42)
        @test wide.value === Durations.Timestamp{Second}(294276, 12, 31, 23, 59, 59)
        @test DBInterface.execute(conn, raw"SELECT $1::timestamp AS value", (wide.value,), typeof(wide)).value === wide.value
        value = MicroTimestamp(2024, 1, 2, 3, 4, 5, 123, 456)
        @test DBInterface.execute(conn, raw"SELECT $1::timestamptz[] AS value", ([value],), NamedTuple{(:value,), Tuple{Vector{MicroTimestamp}}}).value == [value]
        @test only(DBInterface.execute(conn, "SELECT 1 AS value")).value == 1
    end
end
