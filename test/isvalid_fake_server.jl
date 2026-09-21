# isvalid against a scripted server: message shapes a live PostgreSQL cannot be
# made to produce on demand (a notice or parameter change while idle, a warning
# followed by a bare close as on immediate shutdown, protocol garbage, a
# truncated message, a close with no bytes). Reuses the fake-server helpers
# from gssapi.jl.

struct RecordingStyle <: Postgres.API.AbstractPostgresStyle
    notices::Vector{Any}
    notifications::Vector{Postgres.API.Notification}
end
RecordingStyle() = RecordingStyle(Any[], Postgres.API.Notification[])
Postgres.API.notice_callback(s::RecordingStyle, notice) = (push!(s.notices, notice); nothing)
Postgres.API.notification_callback(s::RecordingStyle, n) = (push!(s.notifications, n); nothing)

fields_msg(code::Char, pairs::Pair{Char, String}...) =
    pgmsg(code, vcat([vcat(UInt8(k), Vector{UInt8}(v), 0x00) for (k, v) in pairs]..., 0x00))
notice_msg(severity, sqlstate, text) = fields_msg('N', 'S' => severity, 'V' => severity, 'C' => sqlstate, 'M' => text)
error_response(severity, sqlstate, text) = fields_msg('E', 'S' => severity, 'V' => severity, 'C' => sqlstate, 'M' => text)
notification_msg(pid, channel, payload) =
    pgmsg('A', vcat(be32(pid), Vector{UInt8}(channel), 0x00, Vector{UInt8}(payload), 0x00))

# serve the startup (answering any SSL or GSS request with 'N'), then run `script`
function serve_idle(script)
    return function (sock, n)
        while true
            code, _ = read_request(sock)
            code == 196608 && break
            code in (SSL_REQUEST, GSSENC_REQUEST) || error("unexpected request $code")
            send(sock, [UInt8('N')])
        end
        ready!(sock)
        script(sock)
    end
end

fake_connection(port, style) = Postgres.Connection(host="127.0.0.1", port=port, user="u", dbname="db",
                                                   sslmode="disable", gssencmode="disable", style=style)

function test_isvalid_fake_server()
@testset "isvalid against a scripted server" begin
    @testset "asynchronous messages while idle are dispatched; still valid" begin
        style = RecordingStyle()
        with_fake_server(serve_idle(sock -> begin
            send(sock, param_status("application_name", "changed-by-reload"))
            send(sock, notice_msg("WARNING", "01000", "idle warning"))
            send(sock, notification_msg(99, "chan", "payload"))
            drain(sock)
        end)) do port, accepted
            conn = fake_connection(port, style)
            # the messages may still be in flight: isvalid answers true either
            # way, and once they have landed one call consumes them all
            @test timedwait(() -> (Postgres.isvalid(conn); !isempty(style.notifications)), 5.0) === :ok
            @test Postgres.isvalid(conn)
            @test Postgres.get_server_parameter(conn, "application_name") == "changed-by-reload"
            @test length(style.notices) == 1
            @test any(==("idle warning"), values(style.notices[1]))
            @test length(style.notifications) == 1
            @test style.notifications[1].pid == 99
            @test style.notifications[1].channel == "chan"
            @test style.notifications[1].payload == "payload"
            @test isopen(conn)
            close(conn)
        end
    end

    @testset "warning then close, as on immediate shutdown, is dead" begin
        style = RecordingStyle()
        with_fake_server(serve_idle(sock -> begin
            send(sock, notice_msg("WARNING", "57P02", "terminating connection because of crash of another server process"))
            close(sock)
        end)) do port, accepted
            conn = fake_connection(port, style)
            @test timedwait(() -> !Postgres.isvalid(conn), 5.0) === :ok
            @test !isopen(conn)
            @test length(style.notices) == 1
        end
    end

    @testset "close with no bytes is dead" begin
        style = RecordingStyle()
        with_fake_server(serve_idle(close)) do port, accepted
            conn = fake_connection(port, style)
            @test timedwait(() -> !Postgres.isvalid(conn), 5.0) === :ok
            @test !isopen(conn)
        end
    end

    @testset "a message that cannot occur on an idle session is dead" begin
        for (label, bytes, then_close) in (
                ("unexpected ReadyForQuery", pgmsg('Z', [UInt8('I')]), false),
                ("unsolicited ERROR", error_response("ERROR", "XX000", "unsolicited"), false),
                # the header promises 196 more bytes that never come
                ("truncated message", vcat(UInt8('N'), be32(200)), true),
            )
            @testset "$label" begin
                style = RecordingStyle()
                with_fake_server(serve_idle(sock -> begin
                    send(sock, bytes)
                    then_close ? close(sock) : drain(sock)
                end)) do port, accepted
                    conn = fake_connection(port, style)
                    @test timedwait(() -> !Postgres.isvalid(conn), 5.0) === :ok
                    @test !isopen(conn)
                    @test isempty(style.notices) && isempty(style.notifications)
                end
            end
        end
    end
end
end

struct WaitingValidationStyle <: Postgres.API.AbstractPostgresStyle
    entered::Channel{Nothing}
    release::Base.Event
end
function Postgres.API.notice_callback(style::WaitingValidationStyle, notice)
    put!(style.entered, nothing)
    wait(style.release)
end
struct ThrowingValidationStyle <: Postgres.API.AbstractPostgresStyle end
Postgres.API.notice_callback(::ThrowingValidationStyle, notice) = error("validation callback failed")

function test_isvalid_fragmentation()
    @testset "validation preserves partial messages for normal reads" begin
        message = notification_msg(99, "fragmented", "retained")
        for prefix in (1, 4, 5, length(message)-1), completion in (:validation, :read)
            finish = Base.Event()
            style = RecordingStyle()
            with_fake_server(serve_idle(sock -> begin
                send(sock, message[1:prefix])
                wait(finish)
                send(sock, message[prefix+1:end])
                drain(sock)
            end)) do port, accepted
                conn = fake_connection(port, style)
                try
                    @test !eof(conn.socket.transport)
                    # A same-task callback during a query must not read input.
                    lock(conn.lock) do
                        @test Postgres.isvalid(conn)
                        @test bytesavailable(conn.socket) == 0
                    end
                    @test Postgres.isvalid(conn)
                    @test bytesavailable(conn.socket) == prefix
                    @test isempty(style.notifications)
                    notify(finish)
                    if completion == :validation
                        @test !eof(conn.socket.transport)
                        @test Postgres.isvalid(conn)
                    else
                        notification = Postgres.wait_for_notification(conn; timeout=5)
                        @test notification !== nothing
                        @test notification.payload == "retained"
                    end
                    @test length(style.notifications) == 1
                    @test style.notifications[1].channel == "fragmented"
                    @test Postgres.isvalid(conn)
                finally
                    notify(finish)
                    close(conn)
                end
            end
        end
    end
    @testset "validation callbacks do not hold the pool lock" begin
        send_notice = Base.Event()
        style = WaitingValidationStyle(Channel{Nothing}(1), Base.Event())
        handler = function(sock, n)
            serve_idle(sock -> begin
                if n == 1
                    wait(send_notice)
                    send(sock, notice_msg("NOTICE", "00000", "callback"))
                end
                drain(sock)
            end)(sock, n)
        end
        with_fake_server(handler) do port, accepted
            pool = Postgres.ConnectionPool(() -> fake_connection(port, style); limit=2)
            first = Postgres.acquire(pool)
            Postgres.release(pool, first)
            notify(send_notice)
            @test !eof(first.socket.transport)
            taking = @async Postgres.acquire(pool)
            take!(style.entered)
            other = @async Postgres.acquire(pool)
            try
                @test timedwait(() -> istaskdone(other), 5.0) === :ok
            finally
                notify(style.release)
            end
            first = fetch(taking)
            second = fetch(other)
            @test first !== second
            Postgres.release(pool, first)
            Postgres.release(pool, second)
            @test Postgres.Pools.in_use(pool.pool) == 0
            close(pool)
        end
    end
    @testset "throwing validation returns the pool permit" begin
        send_notice = Base.Event()
        with_fake_server(serve_idle(sock -> begin
            wait(send_notice)
            send(sock, notice_msg("NOTICE", "00000", "callback"))
            drain(sock)
        end)) do port, accepted
            pool = Postgres.ConnectionPool(() -> fake_connection(port, ThrowingValidationStyle()); limit=1)
            conn = Postgres.acquire(pool)
            Postgres.release(pool, conn)
            notify(send_notice)
            @test !eof(conn.socket.transport)
            @test_throws ErrorException Postgres.acquire(pool)
            @test Postgres.Pools.in_use(pool.pool) == 0
            @test !isopen(conn)
            close(pool)
        end
    end
end
