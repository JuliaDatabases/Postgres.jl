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
        ("host=h\xff", nothing, :malformed),
        ("host=h password=se\xffcret", nothing, :malformed),
        # percent-decoding can produce invalid UTF-8 from a valid string
        ("postgresql://u@h/db?reconnect=%ff", "reconnect", :invalid_value),
        ("postgresql://u@h/db?debug=%C3", "debug", :invalid_value),
        ("postgresql://u@h/db?gssdelegation=%ff", "gssdelegation", :invalid_value),
        ("postgresql://u@h/db?sslmode=%ff", "sslmode", :invalid_value),
        ("postgresql://u@h/db?gssencmode=%C3", "gssencmode", :invalid_value),
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
    invalid = ["port=abc", "connect_timeout=x", "sslmode=bogus", "gssencmode=bogus", "gssdelegation=2", "statement_timeout=x",
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
    # a malformed sslmode or gssencmode is reported where lowercase used to throw
    for (dsn, key) in (("postgresql://u@h/db?port=abc&sslmode=%ff", "port"),
                       ("postgresql://u@h/db?connect_timeout=x&gssencmode=%ff", "connect_timeout"),
                       ("postgresql://u@h/db?sslmode=%ff&gssdelegation=2", "sslmode"))
        @test Postgres.validate_dsn(dsn).key == key
    end
    # Windows keeps environment variables as UTF-16, so they cannot hold malformed UTF-8
    if !Sys.iswindows()
        withenv("PGSSLMODE" => "\xff") do
            err = Postgres.validate_dsn("host=h")
            @test err.key == "sslmode" && err.reason === :invalid_value
            thrown = try
                Postgres.parse_dsn("host=h")
            catch e
                e
            end
            @test err.msg == thrown.msg
            @test Postgres.validate_dsn("host=h sslmode=require") === nothing
        end
    end

    @test Postgres.validate_dsn("host=h port=5433 sslmode=require reconnect=on") === nothing
    @test Postgres.validate_dsn("postgresql://u:p@h:5433/db?application_name=app") === nothing
    @test Postgres.validate_dsn("host=h channel_binding=prefer keepalives=1") === nothing
    # only malformed UTF-8 is rejected: lowercase accepts surrogates, and passwords are bytes
    @test Postgres.validate_dsn("host=h password=p\xed\xa0\x80") === nothing
    @test Postgres.parse_dsn("host=h password=p\xed\xa0\x80").password == "p\xed\xa0\x80"
    @test Postgres.parse_dsn("postgresql://u:%ff@h/db").password == "\xff"
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

@testset "sslmode and gssencmode values" begin
    for (key, accepted, envkey) in (("sslmode", ("disable", "prefer", "require", "verify-full"), "PGSSLMODE"),
                                    ("gssencmode", ("disable", "prefer", "require"), "PGGSSENCMODE"))
        field = Symbol(key)
        # every value, in any case, from every source; parse_dsn stores it lowercased
        for mode in accepted, value in (mode, uppercase(mode), titlecase(mode))
            @test getfield(Postgres.parse_dsn("host=h $key=$value"), field) == mode
            @test getfield(Postgres.parse_dsn("postgresql://u@h/db?$key=$value"), field) == mode
            @test Postgres.validate_dsn("host=h $key=$value") === nothing
            withenv(envkey => value) do
                @test getfield(Postgres.parse_dsn("host=h"), field) == mode
            end
            @test getfield(Postgres.ConnectionParams(; field => value), field) == value
        end

        # anything else is rejected when parsing or constructing, not when connecting
        rejected = [("bogus", "bogus"), ("verfy-full", "verfy-full"), ("", ""),
                    ("require ", "require%20"), ("\xed\xa0\x80", "%ed%a0%80")]
        for (value, encoded) in rejected
            msg = "invalid value \"$(escape_string(value))\" for connection parameter \"$key\"; expected one of $(join(accepted, ", "))"
            check = function (dsn)
                err = Postgres.validate_dsn(dsn)
                @test err isa Postgres.ConnectionParameterError
                err isa Postgres.ConnectionParameterError || return
                @test err.key == key
                @test err.reason === :invalid_value
                @test err.msg == msg
                thrown = try
                    Postgres.parse_dsn(dsn)
                catch e
                    e
                end
                @test thrown isa ArgumentError && thrown.msg == msg
            end
            check("host=h $key='$value'")
            check("postgresql://u@h/db?$key=$encoded")
            # an unexpanded ${PGSSLMODE} must fail loudly rather than fall back to the
            # default. Windows keeps environment variables as UTF-16, so they cannot
            # hold a lone surrogate.
            if isvalid(value) || !Sys.iswindows()
                withenv(() -> check("host=h"), envkey => value)
            end
            for construct in (() -> Postgres.ConnectionParams(; field => value),
                              # port 1: a dial would fail with a Postgres.Error instead
                              () -> Postgres.Connection(; host="127.0.0.1", port=1, field => value))
                thrown = try
                    construct()
                catch e
                    e
                end
                @test thrown isa ArgumentError && thrown.msg == msg
            end
        end
    end

    # the Connection constructor's other checks still come first
    @test_throws Postgres.PostgresInterfaceError Postgres.Connection(host="a\0b", port=1, sslmode="bogus")
    @test_throws Postgres.PostgresInterfaceError Postgres.Connection(host="127.0.0.1", port=1, sslcert="c.pem", gssencmode="bogus")

    # the parser, the constructors, and the connect and cancel paths read one
    # list: no other site in src may spell the values out again
    srcdir = joinpath(pkgdir(Postgres), "src")
    code = join((read(joinpath(dir, f), String) for (dir, _, files) in walkdir(srcdir) for f in files if endswith(f, ".jl")), "\n")
    @test count(r"\"disable\", \"prefer\", \"require\"", code) == 2
    @test !occursin(r"(== \"(disable|prefer|require|verify-full)\"\s*\|\|\s*\w+\s*){2}", code)
end
