# Support Policy

Postgres.jl supports Julia 1.10 and later. CI tests PostgreSQL 14 through 18
on TCP connections. Unix-domain sockets are not
supported. Database and certificate integration tests run on Linux with Docker
and OpenSSL. The Windows and macOS CI jobs run the parser and API checks;
they also run database tests when a Linux Docker daemon is available.

## TLS

`sslmode=verify-full` verifies the certificate chain and server name. Use a DNS
name as `host`, or set `sslservername` to the DNS name when dialing a resolved
address. IP-address subject-alternative-name matching on a TLS 1.2-only server
is not supported.

Client certificates require both `sslcert` and `sslkey` and use TLS 1.2.
Server-only TLS connections can negotiate TLS 1.2 or TLS 1.3.

`connect_timeout` bounds the TCP connection and TLS handshake. It does not
bound PostgreSQL authentication or query execution. Use `statement_timeout`
for query execution on a direct or session-pooled connection.

Keep a manual transaction or streaming cursor on the task that created it.
Do not run unrelated operations on that connection until the scope ends. Use
`ConnectionPool` to give concurrent tasks separate connections.

## Transaction Poolers

Connection-form `DBInterface.execute(conn, sql, params)` is safe through a
transaction-mode PgBouncer endpoint. Postgres.jl sends each unnamed extended
query as one dependent protocol segment. Explicit named prepared statements
require PgBouncer prepared-statement tracking, such as
`max_prepared_statements > 0`.

A transaction pooler does not preserve session state between logical clients.
Do not use connection-level `statement_timeout`, `set_statement_timeout!`,
`LISTEN`, temporary tables, session advisory locks, or arbitrary `SET` state in
transaction mode. Configure PostgreSQL or the pooler defaults with
`DateStyle=ISO` and `IntervalStyle=postgres`; Postgres.jl needs these text
formats for correct decoding. Use direct connections or session pooling when
the application needs session state.

`set_statement_timeout!` is rejected while a transaction is open. This keeps
the durable reconnect setting consistent with PostgreSQL's transactional `SET`
semantics.

## Types

Built-in scalar types, byte arrays, and one-dimensional PostgreSQL arrays can
be bound as parameters. Custom enum, composite, and range registration is a
result-decoding feature. Bind a text representation with an explicit SQL
cast when writing those custom values. Multidimensional Julia arrays are not a
supported parameter form.

`time`, `interval`, `timestamp`, and `timestamptz` decoding retains PostgreSQL's
microsecond precision. Timestamps use `Durations.Timestamp{Dates.Microsecond}`.
`timestamptz` is returned in UTC without retaining the original timezone.
PostgreSQL timestamps beyond this type's upper limit in year 294247 raise an
error. Read those values as text, request a wider-range Timestamp resolution in
a typed result, or use a custom parser. Explicit typed `DateTime` fields
truncate to milliseconds. Timestamp parameters with submicrosecond precision raise an error.

`numeric` uses `DataDecimals.DecimalValue{DataDecimals.Int256}`. Values that
cannot fit exactly, including `NaN` and infinities, return their original text
with a warning. Set `numeric_overflow=:error` to throw instead. This policy also
applies to numeric array elements and range bounds. Explicitly typed decimal
results always require an exact conversion; excess precision raises an error.

`boolean` and `bit(1)` decode to `Bool`. Wider `bit(n)` values cannot be
represented as a Boolean and raise an error. Select them as text, for example
`SELECT flags::text FROM my_table`.

## Native Compilation

JuliaC `--trim` compilation is not supported in Postgres.jl. Normal Julia
package precompilation is supported and is part of CI.
