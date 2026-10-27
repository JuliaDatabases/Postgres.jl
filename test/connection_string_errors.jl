@testset "Credential-safe connection string errors" begin
    malformed = (
        ("postgresq://u:s3cr3t@h/db", "s3cr3t"),
        ("postgresq://u:s3cr3t@h/db?sslmode=disable", "s3cr3t"),
        (" postgresq://u:s3cr3t@h/db", "s3cr3t"),
        ("postgresql://u:s3cr%zzt@h/db", "s3cr"),
        ("postgresql://u:s3cr/t@h/db", "s3cr"),
        ("postgresql://u:s3cr?t@h/db", "s3cr"),
        ("postgresql://u@h/db?password=bad%qz", "qz"),
        ("postgresql://u@h/db?password=bad%", "bad"),
        ("postgresql://u@h/db?s3cr3t=value", "s3cr3t"),
        ("host=h password=first s3cr3t", "s3cr3t"),
        ("host=h password=first s3cr3t='unfinished", "s3cr3t"),
    )
    for (dsn, secret) in malformed
        for parse in (Postgres.parse_dsn,
                      s -> DBInterface.connect(Postgres.Connection, s),
                      Postgres.ConnectionPool)
            err, chain = try
                parse(dsn)
                (nothing, "")
            catch e
                (e, sprint(showerror, Base.current_exceptions()))
            end
            @test err isa ArgumentError
            if err !== nothing
                @test !occursin(secret, sprint(showerror, err))
                @test !occursin(secret, chain)
            end
        end
        err = Postgres.validate_dsn(dsn)
        @test err isa Postgres.ConnectionParameterError
        @test !occursin(secret, sprint(showerror, err))
        @test err.key === nothing || !occursin(secret, err.key)
    end

    # Known option errors still identify the option without exposing a password.
    for (dsn, key) in (("host=h password=s3cr3t port=abc", "port"),
                       ("postgresql://u:s3cr3t@h/db?reconnect=ture", "reconnect"),
                       ("postgresql://u@h/db?sslpassword=s3cr3t", "sslpassword"))
        err = try
            Postgres.parse_dsn(dsn)
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(key, sprint(showerror, err))
        @test !occursin("s3cr3t", sprint(showerror, err))
    end

    @test Postgres.parse_dsn("host=h password='x https://example.com'").password == "x https://example.com"
    @test Postgres.parse_dsn("host=h password='s3cr/t'").password == "s3cr/t"
    for scheme in ("postgres", "postgresql")
        @test Postgres.parse_dsn("$scheme://u:s3cr%2Ft@h/db").password == "s3cr/t"
    end
end

@testset "Structured connection string errors" begin
    cases = (
        ("host=h ssl_mode=verify-full", nothing, :unknown_key),
        ("postgresql://u@h/db?ssl_mode=require", nothing, :unknown_key),
        ("host=h channel_binding=require", "channel_binding", :unsupported_ignored),
        ("postgresql://u@h/db?target_session_attrs=read-write", "target_session_attrs", :unsupported_ignored),
        ("host=h port=abc", "port", :invalid_value),
        ("postgresql://u@h:5432/db?connect_timeout=x", "connect_timeout", :invalid_value),
        ("host=h statement_timeout=1.5", "statement_timeout", :invalid_value),
        ("host=h statement_cache_maxsize=many", "statement_cache_maxsize", :invalid_value),
        ("host=h reconnect=ture", "reconnect", :invalid_value),
        ("host=h debug=maybe", "debug", :invalid_value),
        ("host=h gssdelegation=2", "gssdelegation", :invalid_value),
        ("host=h numeric_overflow=ignore", "numeric_overflow", :invalid_value),
        ("=x", nothing, :malformed),
        ("host=h user", "user", :malformed),
        ("host=abc\\", "host", :malformed),
        ("host='abc\\", "host", :malformed),
        ("host='unterminated", "host", :malformed),
        ("host='h'trailing", "host", :malformed),
        ("postgresql://u:p@h:notaport/db", nothing, :malformed),
        # the key names the parameter even when the value imitates another message
        ("host=h port='1\\\" for connection parameter \\\"password'", "port", :invalid_value),
    )
    for (dsn, key, reason) in cases
        err = Postgres.validate_dsn(dsn)
        @test err isa Postgres.ConnectionParameterError
        err isa Postgres.ConnectionParameterError || continue
        @test err.key == key
        @test err.reason === reason
        # same message as the ArgumentError parse_dsn throws for the same input
        thrown = try
            Postgres.parse_dsn(dsn)
        catch e
            e
        end
        @test thrown isa ArgumentError
        @test err.msg == thrown.msg
        @test sprint(showerror, err) == err.msg
    end

    # the DSN check reports what the ConnectionParams constructor throws
    thrown = try
        Postgres.ConnectionParams(numeric_overflow=:ignore)
    catch e
        e
    end
    @test Postgres.validate_dsn("host=h numeric_overflow=ignore").msg == thrown.msg

    # values are checked in the order parse_dsn reports them
    invalid = ["port=abc", "connect_timeout=x", "gssdelegation=2", "statement_timeout=x",
               "statement_cache_maxsize=x", "debug=maybe", "reconnect=ture", "numeric_overflow=ignore"]
    for i in eachindex(invalid)
        dsn = join(["host=h"; invalid[i:end]], " ")
        err = Postgres.validate_dsn(dsn)
        @test err.key == first(split(invalid[i], '='))
        thrown = try
            Postgres.parse_dsn(dsn)
        catch e
            e
        end
        @test err.msg == thrown.msg
    end

    @test Postgres.validate_dsn("host=h port=5433 sslmode=require reconnect=on") === nothing
    @test Postgres.validate_dsn("postgresql://u:p@h:5433/db?application_name=app") === nothing
    @test Postgres.validate_dsn("host=h channel_binding=prefer keepalives=1") === nothing
    withenv("PGPORT" => nothing) do
        @test Postgres.validate_dsn(nothing) === nothing
    end

    # environment defaults are validated as parse_dsn validates them
    withenv("PGPORT" => "abc", "PGGSSDELEGATION" => "maybe") do
        err = Postgres.validate_dsn(nothing)
        @test err.key == "port" && err.reason === :invalid_value
        @test Postgres.validate_dsn("host=h port=5433").key == "gssdelegation"
        thrown = try
            Postgres.parse_dsn(nothing)
        catch e
            e
        end
        @test thrown isa ArgumentError
        @test err.msg == thrown.msg
    end

    # an ignored parameter's rejected value is never echoed: sslpassword is a key passphrase
    for dsn in ("host=h sslpassword=top-secret", "postgresql://u@h/db?sslpassword=top-secret")
        err = Postgres.validate_dsn(dsn)
        @test err.key == "sslpassword"
        @test err.reason === :unsupported_ignored
        @test !occursin("top-secret", sprint(showerror, err))
    end
end
