# Exercise the public bulk API against the scripted wire helpers in gssapi.jl.
# Groups are observed from actual frontend Sync messages, not driver internals.
function bulk_script(groups; fault=:none, tag="INSERT 0 1", backpressure=false, queries=String[])
    return serve_idle(sock -> begin
        status = UInt8('I')
        pending = 0
        row = 0
        failed = false
        while isopen(sock)
            header = readn(sock, 5)
            code = Char(header[1])
            len = rd32(header[2:5]) - 4
            if code == 'B' && row == 1 && fault == :writer_close
                close(sock)
                return
            end
            body = readn(sock, len)
            if code == 'P'
                send(sock, pgmsg('1', UInt8[]))
            elseif code == 'D'
                send(sock, vcat(pgmsg('t', vcat(0x00, 0x02, be32(23), be32(25))), pgmsg('n', UInt8[])))
            elseif code == 'Q'
                query = String(body[1:end-1])
                push!(queries, query)
                status = query == "BEGIN" ? UInt8('T') : UInt8('I')
                failed = false
                send(sock, vcat(pgmsg('C', vcat(codeunits(query), 0x00)), pgmsg('Z', [status])))
            elseif code == 'B'
                pending += 1
                if !failed
                    if row == 1 && fault == :bind_error
                        send(sock, error_response("ERROR", "22P02", "invalid input"))
                        failed = true
                    else
                        send(sock, pgmsg('2', UInt8[]))
                    end
                end
            elseif code == 'E'
                row += 1
                failed && continue
                if row == 2 && backpressure
                    # This execution emits a notice before the server reads
                    # the next row's large Bind. Both directions fill.
                    send(sock, notice_msg("NOTICE", "00000", repeat("n", 8 << 20)))
                end
                if row == 2 && fault in (:error, :fatal_then_close)
                    sqlstate = fault == :error ? "23505" : "57P01"
                    send(sock, error_response("ERROR", sqlstate, "bulk failure"))
                    failed = true
                    fault == :fatal_then_close && (close(sock); return)
                elseif row == 2 && fault == :close
                    close(sock)
                    return
                elseif row == 3 && fault == :missing_complete
                    continue
                elseif row == 2 && fault == :unexpected_bind
                    send(sock, pgmsg('2', UInt8[]))
                elseif row == 2 && fault == :bad_complete
                    send(sock, pgmsg('C', UInt8[0x49]))
                elseif row == 2 && fault == :unexpected_type
                    send(sock, pgmsg('?', UInt8[]))
                elseif row == 2 && fault == :callback
                    send(sock, notice_msg("NOTICE", "00000", "bulk callback"))
                    drain(sock)
                    return
                else
                    send(sock, pgmsg('C', vcat(codeunits(tag), 0x00)))
                end
            elseif code == 'S'
                if pending > 0
                    push!(groups, pending)
                    pending = 0
                    if length(groups) == 2
                        send(sock, param_status("application_name", "bulk-response"))
                        send(sock, notification_msg(99, "bulk", "payload"))
                        if fault == :bad_ready
                            send(sock, pgmsg('Z', UInt8[]))
                            continue
                        elseif fault == :idle_ready
                            send(sock, pgmsg('Z', [UInt8('I')]))
                            continue
                        end
                    end
                end
                send(sock, pgmsg('Z', [failed ? UInt8('E') : status]))
            elseif code == 'C'
                send(sock, pgmsg('3', UInt8[]))
            elseif code == 'X'
                return
            else
                error("unexpected frontend message $code")
            end
        end
    end)
end

struct BulkThrowLogger <: Base.CoreLogging.AbstractLogger end
Base.CoreLogging.min_enabled_level(::BulkThrowLogger) = Base.CoreLogging.Warn
Base.CoreLogging.shouldlog(::BulkThrowLogger, args...) = true
Base.CoreLogging.catch_exceptions(::BulkThrowLogger) = false
Base.CoreLogging.handle_message(::BulkThrowLogger, args...; kwargs...) = error("bulk logger failed")

struct BulkLoggedStyle <: Postgres.AbstractPostgresStyle
    events::Vector{Any}
end
Postgres.query_logging_enabled(::BulkLoggedStyle) = true
Postgres.query_logger(s::BulkLoggedStyle, event::Symbol, info::NamedTuple) =
    (push!(s.events, (event, info)); nothing)
Postgres.notification_callback(s::BulkLoggedStyle, notification) =
    (push!(s.events, notification); nothing)

function test_executemany_protocol()
    @testset "bounded executemany protocol" begin
        for (values, expected) in ((fill("small", 130), [1, 64, 64, 1]),
                                   (vcat("small", fill(repeat("v", 40000), 4)), [1, 2, 2]),
                                   (fill(repeat("v", 100000), 3), [1, 1, 1]))
            groups = Int[]
            with_fake_server(bulk_script(groups)) do port, accepted
                conn = fake_connection(port, Postgres.PostgresStyle())
                try
                    stmt = DBInterface.prepare(conn, raw"INSERT INTO fake VALUES ($1, $2)")
                    @test DBInterface.executemany(stmt, (collect(eachindex(values)), values)) === nothing
                    @test groups == expected
                    @test Postgres.get_server_parameter(conn, "application_name") == "bulk-response"
                    @test all(ismissing, stmt.params)
                    @test !conn.server_in_transaction
                    @test isopen(conn)
                    DBInterface.close!(stmt)
                finally
                    close(conn)
                end
            end
        end
        for tag in ("SET", "CALL", "CREATE TABLE")
            groups = Int[]
            with_fake_server(bulk_script(groups; tag)) do port, accepted
                conn = fake_connection(port, Postgres.PostgresStyle())
                try
                    stmt = DBInterface.prepare(conn, raw"arbitrary command with $1 and $2")
                    @test DBInterface.executemany(stmt, ([1, 2, 3], fill("x", 3))) === nothing
                    @test groups == [1, 1, 1]
                finally
                    close(conn)
                end
            end
        end
        @testset "generic input and callback compatibility" begin
            for params in ((Int[], String[]), ([1, 2], ["x"]), (),
                           ([1, 2, 3],), (ids=[1, 2, 3], values=fill("x", 3)),
                           (1:3, fill("x", 3)), (Any[1, 2, 3], fill("x", 3)),
                           Dict("id" => [1, 2, 3], "value" => fill("x", 3)))
                outcomes = Any[]
                for generic in (true, false)
                    groups, queries = Int[], String[]
                    with_fake_server(bulk_script(groups; queries)) do port, accepted
                        conn = fake_connection(port, Postgres.PostgresStyle())
                        try
                            stmt = DBInterface.prepare(conn, raw"INSERT INTO fake VALUES ($1, $2)")
                            err = connect_err() do
                                if generic
                                    invoke(DBInterface.executemany, Tuple{DBInterface.Statement, Any}, stmt, params)
                                else
                                    DBInterface.executemany(stmt, params)
                                end
                            end
                            push!(outcomes, (err === nothing ? nothing : (typeof(err), sprint(showerror, err)),
                                             sum(groups), copy(queries), isopen(conn)))
                        finally
                            close(conn)
                        end
                    end
                end
                @test outcomes[1] == outcomes[2]
            end
            groups = Int[]
            with_fake_server(bulk_script(groups)) do port, accepted
                style = BulkLoggedStyle(Any[])
                conn = fake_connection(port, style)
                try
                    stmt = DBInterface.prepare(conn, raw"INSERT INTO fake VALUES ($1, $2)")
                    @test DBInterface.executemany(stmt, ([1, 2, 3], fill("x", 3))) === nothing
                    @test groups == [1, 1, 1]
                    @test length(style.events) == 4
                    logs = filter(x -> x isa Tuple, style.events)
                    @test length(logs) == 3
                    @test all(x -> x[1] == :execute && x[2].success, logs)
                    @test [x[2].params[1] for x in logs] == [1, 2, 3]
                    @test only(filter(x -> x isa Postgres.Notification, style.events)).payload == "payload"
                finally
                    close(conn)
                end
            end
        end
        for fault in (:error, :bind_error, :fatal_then_close, :close, :writer_close,
                      :missing_complete, :unexpected_bind, :bad_complete,
                      :unexpected_type, :bad_ready, :idle_ready, :callback)
            @testset "$fault" begin
                groups = Int[]
                with_fake_server(bulk_script(groups; fault)) do port, accepted
                    conn = fake_connection(port, Postgres.PostgresStyle())
                    stmt = DBInterface.prepare(conn, raw"INSERT INTO fake VALUES ($1, $2)")
                    values = fault == :writer_close ? ["small", repeat("x", 8 << 20), "last"] : fill("x", 3)
                    logger = fault == :callback ? BulkThrowLogger() : Base.CoreLogging.NullLogger()
                    task = Base.CoreLogging.with_logger(logger) do
                        @async connect_err(() -> DBInterface.executemany(stmt, ([1, 2, 3], values)))
                    end
                    try
                        ready = timedwait(() -> istaskdone(task), 10.0)
                        @test ready === :ok
                        ready === :ok || Postgres.API.abort(conn.socket)
                        err = fetch(task)
                        @test err !== nothing
                        @test !(err isa TaskFailedException)
                        @test all(ismissing, stmt.params)
                        @test !Postgres.in_transaction(conn)
                        @test isopen(conn) == (fault in (:error, :bind_error))
                        if fault in (:error, :bind_error, :fatal_then_close)
                            @test err isa Postgres.API.Error
                            @test err.code == (fault == :error ? "23505" : fault == :bind_error ? "22P02" : "57P01")
                        elseif fault == :callback
                            @test err isa ErrorException
                            @test occursin("bulk logger failed", sprint(showerror, err))
                        end
                    finally
                        Postgres.API.abort(conn.socket)
                    end
                end
            end
        end
        @testset "duplex progress on bounded large rows" begin
            groups = Int[]
            with_fake_server(bulk_script(groups; backpressure=true)) do port, accepted
                conn = fake_connection(port, Postgres.PostgresStyle())
                stmt = DBInterface.prepare(conn, raw"INSERT INTO fake VALUES ($1, $2)")
                task = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                    @async connect_err(() -> DBInterface.executemany(stmt,
                        ([1, 2, 3, 4], ["small", "small", repeat("x", 8 << 20), "last"])))
                end
                try
                    ready = timedwait(() -> istaskdone(task), 15.0)
                    @test ready === :ok
                    ready === :ok || Postgres.API.abort(conn.socket)
                    @test fetch(task) === nothing
                    @test groups == [1, 2, 1]
                    @test isopen(conn)
                finally
                    Postgres.API.abort(conn.socket)
                end
            end
        end
        @testset "a failed stream can reconnect before the next batch" begin
            groups, queries = Int[], String[]
            handler = (sock, n) -> bulk_script(groups; queries,
                fault=n == 1 ? :fatal_then_close : :none)(sock, n)
            with_fake_server(handler) do port, accepted
                conn = Postgres.Connection(host="127.0.0.1", port=port, user="u", dbname="db",
                    sslmode="disable", gssencmode="disable", reconnect=true)
                try
                    stmt = DBInterface.prepare(conn, raw"INSERT INTO fake VALUES ($1, $2)")
                    params = ([1, 2, 3], fill("x", 3))
                    err = connect_err(() -> DBInterface.executemany(stmt, params))
                    @test err isa Postgres.API.Error && err.code == "57P01"
                    @test !isopen(conn)
                    @test_logs (:warn, r"reconnected") DBInterface.executemany(stmt, params)
                    @test accepted[] == 2
                    @test queries == ["BEGIN", "BEGIN", "COMMIT"]
                    @test isopen(conn)
                    @test !conn.server_in_transaction
                finally
                    close(conn)
                end
            end
        end
    end
end

struct BulkObservedValue
    value::Int
    seen::Vector{Int}
end
function Base.string(p::BulkObservedValue)
    push!(p.seen, p.value)
    p.value == 3 && error("third bulk conversion failed")
    return string(p.value)
end

struct BulkObservedColumn <: AbstractVector{Int}
    values::Vector{Int}
    seen::Vector{Int}
end
Base.size(c::BulkObservedColumn) = size(c.values)
Base.getindex(c::BulkObservedColumn, i::Int) = (push!(c.seen, i); c.values[i])

function test_executemany(conn)
    @testset "executemany data and recovery" begin
        DBInterface.execute(conn, "CREATE TEMP SEQUENCE bulk_attempts")
        DBInterface.execute(conn, "CREATE TEMP TABLE bulk_errors(id int PRIMARY KEY, stamp timestamp, value text, ticket bigint DEFAULT nextval('bulk_attempts'))")
        stmt = DBInterface.prepare(conn, raw"INSERT INTO bulk_errors(id, stamp, value) VALUES ($1, $2, $3)")
        valid = Postgres.API.PGTimestamp(2024, 1, 1, 0, 0, 0, 123, 456)
        invalid = Postgres.API.PGTimestamp(0, 1, 1)
        countrows() = only(DBInterface.execute(conn, "SELECT count(*) AS n FROM bulk_errors")).n
        attempts() = only(DBInterface.execute(conn, "SELECT last_value AS n FROM bulk_attempts")).n
        seen = Int[]
        err = connect_err(() -> DBInterface.executemany(stmt,
            ([1, 1, 3], fill(valid, 3), [BulkObservedValue(i, seen) for i in 1:3])))
        @test err isa Postgres.API.Error
        @test err.code == "23505"
        @test seen == [1, 2]
        @test countrows() == 0
        @test attempts() == 2

        empty!(seen)
        err = connect_err(() -> DBInterface.executemany(stmt,
            (BulkObservedColumn([1, 1, 3], seen), fill(valid, 3), fill("custom column", 3))))
        @test err isa Postgres.API.Error
        @test err.code == "23505"
        @test seen == [1, 2]
        @test countrows() == 0

        for (ids, code) in (([1, 1, 3], "23505"), ([1, 2, 3], nothing))
            before = attempts()
            err = connect_err(() -> DBInterface.executemany(stmt,
                (ids, [valid, valid, invalid], fill("native", 3))))
            if code === nothing
                @test err isa Postgres.PostgresInterfaceError
                @test occursin("BC timestamp", sprint(showerror, err))
            else
                @test err isa Postgres.API.Error
                @test err.code == code
            end
            @test countrows() == 0
            @test attempts() == before + 2
            @test all(ismissing, stmt.params)
            @test !Postgres.in_transaction(conn)
            @test !conn.server_in_transaction
        end
        for duplicate in (2, 64, 65, 66, 130)
            ids = collect(1:130)
            ids[duplicate] = 1
            before = attempts()
            err = connect_err(() -> DBInterface.executemany(stmt, (ids, fill(valid, 130), fill("bulk", 130))))
            @test err isa Postgres.API.Error
            @test err.code == "23505"
            @test countrows() == 0
            @test attempts() == before + duplicate
            @test !conn.server_in_transaction
        end
        for raw_begin in (false, true)
            raw_begin ? DBInterface.execute(conn, "BEGIN") : Postgres.start_transaction(conn)
            DBInterface.execute(conn, "INSERT INTO bulk_errors(id) VALUES (999)")
            err = connect_err(() -> DBInterface.executemany(stmt,
                ([1, 1, 3], fill(valid, 3), fill("nested", 3))))
            @test err isa Postgres.API.Error
            @test err.code == "23505"
            @test countrows() == 1
            @test only(DBInterface.execute(conn, "SELECT id FROM bulk_errors")).id == 999
            @test conn.server_in_transaction
            @test Postgres.in_transaction(conn) == !raw_begin
            raw_begin ? DBInterface.execute(conn, "ROLLBACK") : Postgres.rollback(conn)
            @test countrows() == 0
        end
        params = (id=collect(1:130), stamp=fill(valid, 130), value=Union{Missing, String}[isodd(i) ? missing : "λ $i" for i in 1:130])
        @test DBInterface.executemany(stmt, params) === nothing
        rows = DBInterface.execute(conn, "SELECT id, stamp, value FROM bulk_errors ORDER BY id")
        @test length(rows) == 130
        @test [r.id for r in rows] == params.id
        @test all(r -> r.stamp == valid, rows)
        @test isequal([r.value for r in rows], params.value)
        DBInterface.close!(stmt)

        DBInterface.execute(conn, "CREATE TEMP TABLE bulk_native(id int, data bytea, words text[], nums integer[], amount numeric)")
        native = DBInterface.prepare(conn, raw"INSERT INTO bulk_native VALUES ($1, $2, $3, $4, $5)")
        decimal = parse(Postgres.API.PGDecimal, "12345678901234567890.123456789")
        data = [UInt8[0x00, UInt8(i), 0xff] for i in 1:130]
        words = fill(Union{Missing, String}[missing, "NULL", "\"\\,λ", ""], 130)
        nums = Union{Missing, Vector{Union{Nothing, Int}}}[
            isodd(i) ? missing : Union{Nothing, Int}[1, nothing, -4] for i in 1:130]
        @test DBInterface.executemany(native, (collect(1:130), data, words, nums, fill(decimal, 130))) === nothing
        rows = DBInterface.execute(conn, "SELECT * FROM bulk_native ORDER BY id")
        @test [r.data for r in rows] == data
        @test all(r -> isequal(r.words, words[1]), rows)
        @test all(r -> isequal(r.nums, isodd(r.id) ? missing : [1, missing, -4]), rows)
        @test all(r -> r.amount == decimal, rows)
        DBInterface.close!(native)

        DBInterface.execute(conn, "CREATE TYPE pg_temp.bulk_enum AS ENUM ('ok', 'bad')")
        DBInterface.execute(conn, "CREATE TEMP TABLE bulk_returning(id int, value pg_temp.bulk_enum)")
        oid = only(DBInterface.execute(conn, "SELECT 'pg_temp.bulk_enum'::regtype::oid AS oid")).oid
        parsed = String[]
        Postgres.register_type!(conn, oid, String; parser=(s, registry) -> begin
            push!(parsed, s)
            s == "bad" && error("bulk returning parser failed")
            s
        end)
        err = connect_err(() -> DBInterface.executemany(conn,
            raw"INSERT INTO bulk_returning VALUES ($1, $2) RETURNING value", ([1, 2, 3], ["ok", "bad", "ok"])))
        @test err isa ErrorException
        @test parsed == ["ok", "bad"]
        @test only(DBInterface.execute(conn, "SELECT count(*) AS n FROM bulk_returning")).n == 0
        @test isopen(conn)

        # Commit-time failures must still roll back and leave a reusable session.
        DBInterface.execute(conn, "CREATE TEMP TABLE bulk_deferred(id int UNIQUE DEFERRABLE INITIALLY DEFERRED)")
        err = connect_err(() -> DBInterface.executemany(conn, raw"INSERT INTO bulk_deferred VALUES ($1)", ([1, 1, 3],)))
        @test err isa Postgres.API.Error
        @test err.code == "23505"
        @test only(DBInterface.execute(conn, "SELECT count(*) AS n FROM bulk_deferred")).n == 0
        @test !Postgres.in_transaction(conn)
        @test !conn.server_in_transaction

        DBInterface.execute(conn, "CREATE TEMP TABLE bulk_duplex(id int, value text)")
        DBInterface.execute(conn, raw"""
            CREATE FUNCTION pg_temp.bulk_notice() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF NEW.id = 2 THEN RAISE NOTICE '%', repeat('n', 8388608); END IF;
                RETURN NEW;
            END $$
            """)
        DBInterface.execute(conn, "CREATE TRIGGER bulk_notice BEFORE INSERT ON bulk_duplex FOR EACH ROW EXECUTE FUNCTION pg_temp.bulk_notice()")
        task = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            @async connect_err(() -> DBInterface.executemany(conn,
                raw"INSERT INTO bulk_duplex VALUES ($1, $2)",
                ([1, 2, 3, 4], ["first", "notice", repeat("x", 8 << 20), "last"])))
        end
        finished = timedwait(() -> istaskdone(task), 15.0)
        @test finished === :ok
        finished === :ok || Postgres.API.abort(conn.socket)
        @test fetch(task) === nothing
        @test only(DBInterface.execute(conn, "SELECT sum(octet_length(value)) AS n FROM bulk_duplex")).n == (8 << 20) + 15

        old_limit = conn.statement_cache_maxsize
        try
            Postgres.set_statement_cache_maxsize!(conn, 1)
            sql = raw"INSERT INTO bulk_duplex VALUES ($1, $2)"
            retained = DBInterface.prepare(conn, sql)
            displaced = DBInterface.prepare(conn, "SELECT 42")
            @test DBInterface.executemany(retained, (collect(101:170), fill("retained", 70))) === nothing
            @test length(Postgres.get_cached_statements(conn)) == 1
            @test !haskey(Postgres.get_cached_statements(conn), sql)
            DBInterface.close!(retained)
            DBInterface.close!(displaced)
            Postgres.set_statement_cache_maxsize!(conn, 0)
            @test DBInterface.executemany(conn, sql, (collect(201:270), fill("private", 70))) === nothing
            @test only(DBInterface.execute(conn, "SELECT count(*) AS n FROM pg_prepared_statements")).n == 0
            @test only(DBInterface.execute(conn, "SELECT count(*) AS n FROM bulk_duplex WHERE id >= 100")).n == 140
        finally
            Postgres.set_statement_cache_maxsize!(conn, old_limit)
        end
    end
end

function test_executemany_cancel(conn, observer)
    @testset "cancel a pipelined group" begin
        DBInterface.execute(conn, "CREATE TEMP TABLE bulk_cancel(id int)")
        DBInterface.execute(conn, raw"""
            CREATE FUNCTION pg_temp.bulk_pause() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF NEW.id = 2 THEN PERFORM pg_advisory_xact_lock(732681, 419); END IF;
                RETURN NEW;
            END $$
            """)
        DBInterface.execute(conn, "CREATE TRIGGER bulk_pause BEFORE INSERT ON bulk_cancel FOR EACH ROW EXECUTE FUNCTION pg_temp.bulk_pause()")
        DBInterface.execute(observer, "SELECT pg_advisory_lock(732681, 419)")
        task = @async connect_err(() -> DBInterface.executemany(conn,
            raw"INSERT INTO bulk_cancel VALUES ($1)", (collect(1:130),)))
        try
            blocked = timedwait(5.0; pollint=0.01) do
                only(DBInterface.execute(observer,
                    "SELECT count(*) AS n FROM pg_stat_activity WHERE pid = $(conn.pid) AND wait_event = 'advisory'")).n == 1
            end
            @test blocked === :ok
            Postgres.cancel_query!(conn)
            finished = timedwait(() -> istaskdone(task), 5.0)
            @test finished === :ok
            finished === :ok || Postgres.API.abort(conn.socket)
            err = fetch(task)
            @test err isa Postgres.API.Error
            @test err.code == "57014"
            @test only(DBInterface.execute(conn, "SELECT count(*) AS n FROM bulk_cancel")).n == 0
            @test !Postgres.in_transaction(conn)
            @test !conn.server_in_transaction
            @test isopen(conn)
        finally
            DBInterface.execute(observer, "SELECT pg_advisory_unlock(732681, 419)")
        end
        @test DBInterface.executemany(conn, raw"INSERT INTO bulk_cancel VALUES ($1)", ([1, 2, 3],)) === nothing
        @test only(DBInterface.execute(conn, "SELECT sum(id) AS n FROM bulk_cancel")).n == 6
    end
end
