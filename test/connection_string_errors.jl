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
