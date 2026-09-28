# Scripted peers hold each fragment until the public wait has timed out. The
# watchdog only bounds cleanup if a reader ignores its receive deadline.
function notification_timeout(conn; timeout=0.02)
    expired = Ref(false)
    watchdog = Timer(5) do _
        expired[] = true
        Postgres.API.abort(conn.socket)
    end
    try
        @test Postgres.wait_for_notification(conn; timeout) === nothing
        @test !expired[]
        @test isopen(conn)
    finally
        close(watchdog)
    end
end

function with_notification_peer(f; gss=false)
    peer = Channel{Any}(1)
    handler = if gss
        function (sock, _)
            code, _ = read_request(sock)
            code == GSSENC_REQUEST || error("expected GSS request")
            send(sock, [UInt8('G')])
            io = server_handshake(sock)
            read_startup(io)
            ready!(io)
            put!(peer, io)
            drain(io)
        end
    else
        serve_idle(sock -> (put!(peer, sock); drain(sock)))
    end
    with_fake_server(handler) do port, _
        conn = gss ? Postgres.Connection(host="127.0.0.1", port=port, user="u", dbname="db",
            gssencmode="require", style=FakeGSSStyle()) : fake_connection(port, RecordingStyle())
        try
            f(conn, take!(peer))
        finally
            Postgres.API.abort(conn.socket)
            close(conn)
        end
    end
end

function notification_fragments(conn, send_fragment)
    bytes = notification_msg(99, "deadline", "retained")
    start = 1
    for stop in (1, 4, 5, length(bytes)-1)
        send_fragment(bytes[start:stop])
        @test timedwait(() -> (Postgres.isvalid(conn); bytesavailable(conn.socket) == stop), 5) === :ok
        notification_timeout(conn)
        @test conn.socket.buffer[conn.socket.pos:end] == bytes[1:stop]
        @test Postgres.isvalid(conn)
        start = stop+1
    end
    send_fragment(bytes[start:end])
    n = Postgres.wait_for_notification(conn; timeout=5)
    @test n.channel == "deadline"
    @test n.payload == "retained"
    notification_timeout(conn)
end

struct ThrowingNotificationStyle <: Postgres.API.AbstractPostgresStyle end
Postgres.API.notification_callback(::ThrowingNotificationStyle, n) = error("notification callback failed")

function test_notification_deadlines()
@testset "Notification receive budget" begin
    with_notification_peer() do conn, peer
        notification_fragments(conn, bytes -> send(peer, bytes))
        @test length(conn.style.notifications) == 1
        # Side messages neither discard a partial notification nor change its
        # receive budget. Unknown complete messages retain the skip policy.
        send(peer, vcat(notice_msg("NOTICE", "00000", "before notification"),
            param_status("application_name", "changed"), pgmsg('Y', UInt8[1, 2]),
            notification_msg(1, "side", "next")[1:5]))
        notification_timeout(conn)
        @test length(conn.style.notices) == 1
        @test Postgres.get_server_parameter(conn, "application_name") == "changed"
        send(peer, notification_msg(1, "side", "next")[6:end])
        @test Postgres.wait_for_notification(conn; timeout=5).payload == "next"
        for timeout in (0, -1)
            @test Postgres.wait_for_notification(conn; timeout) === nothing
        end
        for timeout in (nothing, Inf)
            send(peer, notification_msg(1, "side", "unlimited"))
            @test Postgres.wait_for_notification(conn; timeout).payload == "unlimited"
        end
    end
    @testset "callback time reduces the remaining receive budget" begin
        style = WaitingValidationStyle(Channel{Nothing}(1), Base.Event())
        with_fake_server(serve_idle(sock -> begin
            send(sock, vcat(notice_msg("NOTICE", "00000", "wait"),
                notification_msg(1, "after-callback", "buffered")))
            drain(sock)
        end)) do port, _
            conn = fake_connection(port, style)
            started = Ref(UInt64(0))
            reader = @async begin
                started[] = time_ns()
                Postgres.wait_for_notification(conn; timeout=1.0)
            end
            try
                @test timedwait(() -> isready(style.entered) || istaskdone(reader), 5) === :ok
                @test isready(style.entered)
                timer = Timer(max(0.001, 1.02 - (time_ns()-started[])/1e9))
                try
                    wait(timer)
                finally
                    close(timer)
                end
                @test !istaskdone(reader) # callbacks are deliberately not interrupted
                notify(style.release)
                @test fetch(reader) === nothing
                @test Postgres.wait_for_notification(conn; timeout=5).payload == "buffered"
            finally
                notify(style.release)
                close(conn)
                wait(reader)
            end
        end
    end
    @testset "callback exceptions preserve aligned input" begin
        for (style, bytes, text) in (
            (ThrowingValidationStyle(), notice_msg("NOTICE", "00000", "callback"), "validation callback failed"),
            (ThrowingNotificationStyle(), notification_msg(1, "callback", "first"), "notification callback failed"),
        )
            with_fake_server(serve_idle(sock -> begin
                send(sock, vcat(bytes, param_status("application_name", "after-callback")))
                drain(sock)
            end)) do port, _
                conn = fake_connection(port, style)
                try
                    err = connect_err(() -> Postgres.wait_for_notification(conn; timeout=5))
                    @test err isa ErrorException
                    @test occursin(text, sprint(showerror, err))
                    @test isopen(conn)
                    notification_timeout(conn)
                    @test Postgres.get_server_parameter(conn, "application_name") == "after-callback"
                finally
                    close(conn)
                end
            end
        end
    end
    @testset "protocol and server errors" begin
        for (bytes, then_close, error_type, remains_open) in (
            (vcat(UInt8('A'), be32(3)), false, Postgres.API.Error, false),
            (notification_msg(1, "truncated", "body")[1:7], true, EOFError, false),
            (UInt8['A', 0], true, EOFError, false),
            (UInt8[], true, EOFError, false),
            (error_response("ERROR", "XX000", "server error"), false, Postgres.API.Error, true),
            (error_response("FATAL", "XX000", "server error"), false, Postgres.API.Error, false),
            (error_response("PANIC", "XX000", "server error"), false, Postgres.API.Error, false),
        )
            with_fake_server(serve_idle(sock -> begin
                send(sock, bytes)
                then_close ? close(sock) : drain(sock)
            end)) do port, _
                conn = fake_connection(port, RecordingStyle())
                try
                    err = connect_err(() -> Postgres.wait_for_notification(conn; timeout=5))
                    @test err isa error_type
                    @test isopen(conn) == remains_open
                finally
                    close(conn)
                end
            end
        end
    end
end
end

function test_notification_gss_deadlines()
@testset "Notification GSS receive budget" begin
    with_notification_peer(gss=true) do conn, peer
        notification_fragments(conn, bytes -> send(peer, bytes))
        payload = notification_msg(1, "gss-record", "resumed")
        wire = vcat(be32(length(payload)+1), FAKE_SEAL, payload)
        start = 1
        for stop in (1, 3, 4, length(wire)-1)
            send(peer.sock, wire[start:stop])
            @test timedwait(() -> (Postgres.isvalid(conn); conn.socket.transport.received == stop), 5) === :ok
            notification_timeout(conn)
            @test conn.socket.transport.received == stop
            start = stop+1
        end
        send(peer.sock, wire[start:end])
        @test Postgres.wait_for_notification(conn; timeout=5).payload == "resumed"
    end
    for prefix in (0, 3, 7)
        with_notification_peer(gss=true) do conn, peer
            wire = vcat(be32(30), FAKE_SEAL, zeros(UInt8, 29))
            send(peer.sock, wire[1:prefix])
            close(peer.sock)
            err = connect_err(() -> Postgres.wait_for_notification(conn; timeout=5))
            @test err isa (prefix == 0 ? EOFError : Postgres.API.Error)
            @test !isopen(conn)
        end
    end
end
    test_notification_gss_read_budget()
end

const NotificationTransport = Union{Postgres.Reseau.TCP.Conn, Postgres.Reseau.TLS.Conn}
readn(io::NotificationTransport, n) = read!(io, Vector{UInt8}(undef, n))
send(io::NotificationTransport, bytes) = write(io, bytes)

function with_notification_tls_peer(f, config)
    tcp = Postgres.Reseau.TCP
    tls = Postgres.Reseau.TLS
    listener = tcp.listen(tcp.loopback_addr(0))
    peer = Channel{tls.Conn}(1)
    accepted = Ref{Union{Nothing, tcp.Conn}}(nothing)
    task = @async begin
        raw = tcp.accept(listener)
        accepted[] = raw
        try
            code, _ = read_request(raw)
            code == SSL_REQUEST || error("expected SSL request")
            write(raw, UInt8('S'))
            io = tls.server(raw, config)
            tls.handshake!(io)
            read_startup(io)
            ready!(io)
            put!(peer, io)
            drain(io)
        finally
            close(raw)
        end
    end
    watchdog = Timer(20) do _
        close(listener)
        accepted[] === nothing || close(accepted[])
    end
    conn = nothing
    try
        conn = Postgres.Connection(host="127.0.0.1", port=Int(tcp.addr(listener).port),
            user="u", dbname="db", sslmode="require", gssencmode="disable", style=RecordingStyle())
        f(conn, take!(peer))
    finally
        conn === nothing || Postgres.API.abort(conn.socket)
        accepted[] === nothing || close(accepted[])
        close(listener)
        close(watchdog)
        wait(task)
    end
end

# Capture one record encrypted with this peer's live keys on another socket.
# Sending its bytes on the real connection permits splits inside TLS framing.
function notification_tls_record(peer, payload)
    tcp = Postgres.Reseau.TCP
    tls = Postgres.Reseau.TLS
    listener = tcp.listen(tcp.loopback_addr(0))
    sender = tcp.connect(tcp.addr(listener))
    receiver = tcp.accept(listener)
    try
        state = peer.native_state
        if state isa tls._TLS13NativeClientState
            tls._tls13_write_record!(sender, state, tls._TLS_RECORD_TYPE_APPLICATION_DATA, payload)
        else
            tls._tls12_write_record!(sender, state, tls._TLS_RECORD_TYPE_APPLICATION_DATA, payload)
        end
        header = readn(receiver, 5)
        return vcat(header, readn(receiver, (Int(header[4]) << 8) | Int(header[5])))
    finally
        close(sender)
        close(receiver)
        close(listener)
    end
end

function test_notification_tls_deadlines()
@testset "Notification TLS receive budget" begin
    if Sys.which("openssl") === nothing
        @test_skip false
    else
        mktempdir() do dir
            generate_ssl_material(dir)
            tls = Postgres.Reseau.TLS
            for version in (tls.TLS1_2_VERSION, tls.TLS1_3_VERSION)
                config = tls.Config(verify_peer=false, cert_file=joinpath(dir, "server.crt"),
                    key_file=joinpath(dir, "server.key"), min_version=version, max_version=version)
                with_notification_tls_peer(config) do conn, peer
                    notification_fragments(conn, bytes -> send(peer, bytes))
                    wire = notification_tls_record(peer, notification_msg(1, "tls-record", "resumed"))
                    start = 1
                    for stop in (1, 4, 5, length(wire)-1)
                        write(peer.tcp, wire[start:stop])
                        @test timedwait(() -> (Postgres.isvalid(conn); conn.socket.transport.native_state.record_received == stop), 5) === :ok
                        notification_timeout(conn)
                        @test conn.socket.transport.native_state.record_received == stop
                        start = stop+1
                    end
                    write(peer.tcp, wire[start:end])
                    @test Postgres.wait_for_notification(conn; timeout=5).payload == "resumed"
                    @test length(conn.style.notifications) == 2
                end
                for prefix in (0, 3, 7)
                    with_notification_tls_peer(config) do conn, peer
                        wire = notification_tls_record(peer, notification_msg(1, "tls-eof", "truncated"))
                        write(peer.tcp, wire[1:prefix])
                        close(peer.tcp)
                        err = connect_err(() -> Postgres.wait_for_notification(conn; timeout=5))
                        @test err isa (prefix == 0 ? EOFError : tls.TLSError)
                        @test !isopen(conn)
                    end
                end
            end
        end
    end
end
end

function test_notification_gss_read_budget()
    @testset "Notification in the sixteenth GSS record" begin
        with_notification_peer(gss=true) do conn, peer
            send(peer, notification_msg(1, "warmup", "complete"))
            @test Postgres.wait_for_notification(conn; timeout=5).payload == "complete"
            payload = notification_msg(1, "gss-budget", "sixteenth")
            wire = vcat(repeat(vcat(be32(1), FAKE_SEAL), 15), be32(length(payload)+1), FAKE_SEAL, payload)
            send(peer.sock, wire)
            transport = conn.socket.transport
            deadline = time_ns() + UInt64(5_000_000_000)
            Postgres.API.set_read_deadline!(transport, deadline)
            try
                @test !eof(transport.tcp)
                peeked = similar(wire)
                socketops = Postgres.API.Reseau.SocketOps
                while true
                    available = GC.@preserve peeked socketops.recv_from!(
                        transport.tcp.fd.pfd.sysfd, pointer(peeked),
                        Csize_t(length(peeked)), socketops.MSG_PEEK)
                    available > 0 || error("fixture socket lost readability")
                    available == length(peeked) && break
                    time_ns() < deadline || error("complete GSS fixture did not arrive")
                    yield()
                end
                @test peeked == wire
            finally
                Postgres.API.set_read_deadline!(transport, 0)
            end
            reader = @async Postgres.wait_for_notification(conn; timeout=5)
            tcp = conn.socket.transport.tcp
            waiter = Postgres.Reseau.IOPoll._poll_registration(tcp.fd.pfd.pd).read_waiter
            watchdog = Timer(_ -> close(tcp), 5)
            local n, completed_without_wait
            try
                while !istaskdone(reader) && (@atomic :acquire waiter.state) !== reader
                    yield()
                end
                completed_without_wait = istaskdone(reader)
                n = fetch(reader)
            finally
                close(watchdog)
            end
            @test completed_without_wait # local plaintext must not cause a raw readiness wait
            @test n !== nothing
            if n !== nothing
                @test n.channel == "gss-budget"
                @test n.payload == "sixteenth"
            end
            notification_timeout(conn)
        end
    end
end
