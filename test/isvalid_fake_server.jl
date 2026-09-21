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
            @test timedwait(() -> (isvalid(conn); !isempty(style.notifications)), 5.0) === :ok
            @test isvalid(conn)
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
            @test timedwait(() -> !isvalid(conn), 5.0) === :ok
            @test !isopen(conn)
            @test length(style.notices) == 1
        end
    end

    @testset "close with no bytes is dead" begin
        style = RecordingStyle()
        with_fake_server(serve_idle(close)) do port, accepted
            conn = fake_connection(port, style)
            @test timedwait(() -> !isvalid(conn), 5.0) === :ok
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
                    @test timedwait(() -> !isvalid(conn), 5.0) === :ok
                    @test !isopen(conn)
                    @test isempty(style.notices) && isempty(style.notifications)
                end
            end
        end
    end
end
end
