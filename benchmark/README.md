# Bulk execution

Use a disposable local PostgreSQL server with a trust-authenticated `postgres`
user and database. The benchmark uses only a temporary table. Pass its local
port, the row count, and bytes per text parameter:

```sh
julia --project benchmark/executemany.jl 5432 128 12
```

The serial control invokes DBInterface's generic method on the same statement.
Both variants are warmed, then measured in alternating order. Each sample checks
the stored row count, ID sum, and text byte count outside the timed call. Output
includes every sample, median/range elapsed time, client process CPU time on
Unix, allocation bytes, and Julia's reported compilation time when available.

To count actual protocol messages and inject a repeatable acknowledgment delay,
run the Python standard-library proxy in another terminal, then benchmark its
port. Arguments are listener port, PostgreSQL port, and delay in milliseconds:

```sh
python3 benchmark/postgres_proxy.py 6543 5432 4
julia --project benchmark/executemany.jl 6543 128 12
```

The proxy listens on loopback and records only message-type counts between
BEGIN and COMMIT/ROLLBACK, including the final ReadyForQuery. It never logs SQL
or parameter values. A nominal delay before ReadyForQuery is a controlled
fixture, not a simulation of all network latency. Use delay `0` for the matched
proxy baseline; loopback throughput does not establish cloud throughput.
