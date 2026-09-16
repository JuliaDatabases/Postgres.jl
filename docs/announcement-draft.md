# [ANN] Postgres.jl: a PostgreSQL client written in Julia

I'd like to invite people to try [Postgres.jl](https://github.com/JuliaDatabases/Postgres.jl), a PostgreSQL client that implements the wire protocol in Julia and works with DBInterface.jl and Tables.jl.

It supports parameterized queries, prepared statements, nested transactions, COPY, cursor streaming, LISTEN/NOTIFY, connection pooling, and direct result decoding into Julia structs with StructUtils.jl. It uses Reseau.jl for networking and TLS.

Install it with:

```julia
using Pkg
Pkg.add("Postgres")
```

Here is a complete example for a local PostgreSQL server:

```julia
using Postgres

DBInterface.connect(Postgres.Connection,
    "postgresql://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable",
) do conn
    row = only(DBInterface.execute(conn, raw"SELECT $1::int AS answer", (42,)))
    @show row.answer # 42

    Postgres.transaction(conn) do tx
        DBInterface.execute(tx, "CREATE TEMP TABLE demo (id int, name text)")
        DBInterface.execute(tx, raw"INSERT INTO demo VALUES ($1, $2)", (1, "Julia"))
    end

    for row in DBInterface.execute(conn, "SELECT id, name FROM demo")
        @show row.id row.name
    end
end
```

The example disables TLS for local testing. For a remote database, use `sslmode=verify-full` and your provider's CA configuration.

The package supports Julia 1.10 and later. Database integration tests cover PostgreSQL 14–18, including SCRAM and MD5 authentication, certificate verification, cancellation, and recovery after errors. The suite also uses seeded randomized tests to check values against a real PostgreSQL server.

There are limits to call out. Connections use TCP; Unix-domain sockets are not supported. Timestamps use Durations.jl with microsecond precision. Decimals use DataDecimals.jl, with an exact fallback for larger PostgreSQL numeric values. Custom composite, enum, and range registration controls result decoding; use text parameters with explicit casts when writing those types. See the [support policy](https://JuliaDatabases.github.io/Postgres.jl/dev/support/) for TLS and transaction-pooler details.

I would welcome reports from real workloads, especially type conversion, managed PostgreSQL services, and connection-pooler setups. Please include a small example and version information in [an issue](https://github.com/JuliaDatabases/Postgres.jl/issues), with credentials and private data removed.

Implementation and review used Claude Code and OpenAI Codex. The repository records the source history, review discussions, and validation work.

[Documentation](https://JuliaDatabases.github.io/Postgres.jl/dev/) · [Source](https://github.com/JuliaDatabases/Postgres.jl)

<!-- Maintainer: publish after the hardening PR is merged, a release with these changes is
registered, and a clean install of that release passes this example. Recheck
links and the support policy against the released version before posting. -->
