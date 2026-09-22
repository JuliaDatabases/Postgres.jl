# GSSAPI without a KDC. FakeGSS stands in for the system Kerberos library:
# tokens are fixed byte strings and "sealing" prefixes a marker byte, so the
# driver's negotiation, framing, chunking, redaction, and error paths run on
# every CI platform against a scripted server on a loopback port.

const GSSAPI = Postgres.API.SASLAuth.GSSAPI

mutable struct FakeGSS
    target::String
    delegate::Bool
    encrypt::Bool
    state::Int
    closed::Bool
end
const FAKE_CLIENT_TOKEN = Vector{UInt8}("client-token")
const FAKE_SERVER_TOKEN = Vector{UInt8}("server-token")
const FAKE_SEAL = 0xa5

include("gssapi_native_mock.jl")

mutable struct FakeGSSStyle <: Postgres.API.AbstractPostgresStyle
    credentials::Bool
    contexts::Vector{FakeGSS}
end
FakeGSSStyle(credentials::Bool=true) = FakeGSSStyle(credentials, FakeGSS[])
Postgres.API.gss_has_credentials(style::FakeGSSStyle) = style.credentials
function Postgres.API.gss_context(style::FakeGSSStyle, target::String, delegate::Bool, encrypt::Bool)
    ctx = GSSAPI.Context(target; delegate, encrypt)
    push!(FAKE_CONTEXTS, ctx)
    push!(style.contexts, FAKE_NAMES[ctx.target])
    return ctx
end

# ── wire helpers (server side) ──
const SSL_REQUEST = Int32(80877103)
const GSSENC_REQUEST = Int32(80877104)
const CANCEL_REQUEST = Int32(80877102)
be32(x::Integer) = reinterpret(UInt8, [hton(Int32(x))])
rd32(b::AbstractVector{UInt8}) = ntoh(reinterpret(Int32, b[1:4])[1])
pgmsg(code::Char, body::AbstractVector{UInt8}) = vcat(UInt8(code), be32(4 + length(body)), body)
param_status(k, v) = pgmsg('S', vcat(Vector{UInt8}(k), 0x00, Vector{UInt8}(v), 0x00))
auth_msg(code::Integer, body::AbstractVector{UInt8}=UInt8[]) = pgmsg('R', vcat(be32(code), body))
error_msg(text::String) = pgmsg('E', vcat(Vector{UInt8}("SFATAL"), 0x00, Vector{UInt8}("VFATAL"), 0x00,
                                         Vector{UInt8}("C28000"), 0x00, Vector{UInt8}("M" * text), 0x00, 0x00))
ready_bundle() = vcat(param_status("client_encoding", "UTF8"), param_status("DateStyle", "ISO, MDY"),
                      param_status("IntervalStyle", "postgres"), param_status("server_version", "16.0"),
                      pgmsg('K', vcat(be32(4242), be32(777))), pgmsg('Z', [UInt8('I')]))

# the server end of the fake GSS transport: frames in, unsealed plaintext out
struct ServerGSS
    sock::Sockets.TCPSocket
    inbuf::IOBuffer
end
ServerGSS(sock) = ServerGSS(sock, PipeBuffer())
readframe(sock::Sockets.TCPSocket) = read(sock, Int(ntoh(read(sock, UInt32))))
writeframe(sock::Sockets.TCPSocket, token) = (write(sock, hton(UInt32(length(token)))); write(sock, token); flush(sock))
# Base's read(sock, n) returns a short vector at EOF; the scripts need an
# exception there so `drain` ends when the client closes
function readn(sock::Sockets.TCPSocket, n)
    bytes = read(sock, n)
    length(bytes) == n || throw(EOFError())
    return bytes
end
send(sock::Sockets.TCPSocket, bytes) = (write(sock, bytes); flush(sock))
function readn(s::ServerGSS, n)
    while bytesavailable(s.inbuf) < n
        token = readframe(s.sock)
        token[1] == FAKE_SEAL || error("fake server: bad seal from client")
        write(s.inbuf, token[2:end])
    end
    return read(s.inbuf, n)
end
send(s::ServerGSS, bytes) = writeframe(s.sock, vcat(FAKE_SEAL, bytes))
function server_handshake(sock)
    readframe(sock) == FAKE_CLIENT_TOKEN || error("fake server: bad client token")
    writeframe(sock, FAKE_SERVER_TOKEN)
    return ServerGSS(sock)
end
# the 8-byte SSLRequest / GSSENCRequest, or a 16-byte CancelRequest
function read_request(io)
    len = rd32(readn(io, 4))
    body = readn(io, len - 4)
    return rd32(body), body[5:end]
end
function read_startup(io)
    len = rd32(readn(io, 4))
    body = readn(io, len - 4)
    rd32(body) == 196608 || error("fake server: bad protocol version")
    parts = split(String(body[5:end-1]), '\0')
    return Dict(parts[i] => parts[i+1] for i in 1:2:length(parts)-1)
end
function read_message(io)
    hdr = readn(io, 5)
    return Char(hdr[1]), readn(io, rd32(hdr[2:5]) - 4)
end
# hold the connection open until the client closes it
function drain(io)
    try
        while true; readn(io, 1); end
    catch
    end
end
ready!(io) = foreach(chunk -> send(io, collect(chunk)), Iterators.partition(vcat(auth_msg(0), ready_bundle()), 13))

# A scripted PostgreSQL server on a loopback port. `handler(io, n)` serves the
# n-th accepted connection; assertion failures inside it are collected.
function with_fake_server(f, handler)
    server = Sockets.listen(Sockets.ip"127.0.0.1", 0)
    _, port = Sockets.getsockname(server)
    accepted = Ref(0)
    failures = String[]
    tasks = Task[]
    acceptor = @async while isopen(server)
        sock = try
            Sockets.accept(server)
        catch
            break
        end
        n = (accepted[] += 1)
        push!(tasks, @async try
            handler(sock, n)
        catch err
            # the client closing early is expected on error paths
            err isa ErrorException && push!(failures, err.msg)
        finally
            close(sock)
        end)
    end
    try
        f(Int(port), accepted)
    finally
        close(server)
        wait(acceptor)
        timedwait(() -> all(istaskdone, tasks), 10.0)
    end
    @test isempty(failures)
    return
end

connect_err(f) = try; f(); nothing; catch err; err; end
errtext(err) = sprint(showerror, err)

function test_gssapi_protocol()
@testset "GSSAPI Without A KDC" begin
    @testset "GSS encryption: handshake, chunked framing, cancel, deadline" begin
        style = FakeGSSStyle()
        cancel_seen = Ref{Any}(nothing)
        handler = function (sock, n)
            code, _ = read_request(sock)
            code == GSSENC_REQUEST || error("expected GSSENCRequest, got $code")
            send(sock, [UInt8('G')])
            io = server_handshake(sock)
            if n == 1
                params = read_startup(io)
                params["user"] == "krbuser" && params["database"] == "db" || error("bad startup params: $params")
                params["options"] == "-c search_path=public" || error("missing startup options")
                ready!(io)
                drain(io)
            else
                code, body = read_request(io)
                code == CANCEL_REQUEST || error("expected CancelRequest, got $code")
                cancel_seen[] = (rd32(body[1:4]), rd32(body[5:8]))
            end
        end
        with_fake_server(handler) do port, accepted
            conn = Postgres.Connection(host="127.0.0.1", port=port, user="krbuser", dbname="db",
                                       gssencmode="require", krbsrvname="POSTGRES", gssdelegation=true,
                                       options="-c search_path=public", style=style)
            @test conn.socket.transport isa Postgres.API.GSSConn
            @test fieldtype(Postgres.API.GSSConn, :ctx) === GSSAPI.Context
            @test isopen(conn)
            @test conn.pid == 4242
            @test length(style.contexts) == 1
            @test style.contexts[1].target == "POSTGRES@127.0.0.1"
            @test style.contexts[1].encrypt && style.contexts[1].delegate
            # the deadline plumbing on the GSS transport: nothing arrives, nothing is consumed
            @test Postgres.wait_for_notification(conn; timeout=0.2) === nothing
            @test isopen(conn)
            # the non-blocking read behind isvalid also runs through the GSS
            # transport: an idle fake server means nothing pending, alive
            @test Postgres.isvalid(conn)
            # the cancel key travels over a GSS-encrypted connection too
            Postgres.cancel_query!(conn)
            timedwait(() -> cancel_seen[] !== nothing, 5.0)
            @test cancel_seen[] == (4242, 777)
            @test length(style.contexts) == 2 && style.contexts[2].encrypt
            close(conn)
            @test style.contexts[1].closed
            @test accepted[] == 2
        end
    end

    @testset "GSS encryption via DSN and env" begin
        style = FakeGSSStyle()
        handler = function (sock, n)
            code, _ = read_request(sock)
            code == GSSENC_REQUEST || error("expected GSSENCRequest, got $code")
            send(sock, [UInt8('G')])
            io = server_handshake(sock)
            read_startup(io)
            ready!(io)
            drain(io)
        end
        with_fake_server(handler) do port, accepted
            withenv("PGGSSENCMODE" => "prefer", "PGKRBSRVNAME" => "pgsvc") do
                conn = DBInterface.connect(Postgres.Connection, "postgresql://krbuser@127.0.0.1:$port/db"; style=style)
                @test conn.socket.transport isa Postgres.API.GSSConn
                @test style.contexts[1].target == "pgsvc@127.0.0.1"
                @test !style.contexts[1].delegate
                close(conn)
            end
        end
    end

    @testset "server answers GSSENCRequest with N" begin
        for mode in ("require", "prefer")
            style = FakeGSSStyle()
            handler = function (sock, n)
                code, _ = read_request(sock)
                code == GSSENC_REQUEST || error("expected GSSENCRequest, got $code")
                send(sock, [UInt8('N')])
                mode == "prefer" || return
                read_startup(sock)
                ready!(sock)
                drain(sock)
            end
            with_fake_server(handler) do port, accepted
                err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode=mode, sslmode="disable", style=style))
                if mode == "require"
                    @test err isa Postgres.Error
                    @test err.message == "server doesn't support GSSAPI encryption, but it was required"
                else
                    # prefer continues on the same connection without GSS
                    @test err === nothing
                end
                @test accepted[] == 1
                @test isempty(style.contexts)
            end
        end
    end

    @testset "server answers GSSENCRequest with an error (text never shown)" begin
        for mode in ("require", "prefer")
            style = FakeGSSStyle()
            handler = function (sock, n)
                code, _ = read_request(sock)
                if n == 1
                    code == GSSENC_REQUEST || error("expected GSSENCRequest, got $code")
                    send(sock, vcat(UInt8('E'), error_msg("injected pre-auth text")[2:end]))
                    return
                end
                code == SSL_REQUEST || error("retry must not ask for GSS again, got $code")
                send(sock, [UInt8('N')])
                read_startup(sock)
                ready!(sock)
                drain(sock)
            end
            with_fake_server(handler) do port, accepted
                err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode=mode, style=style))
                if mode == "require"
                    @test err isa Postgres.Error
                    @test err.message == "server sent an error response during GSS encryption exchange"
                    @test !occursin("injected", errtext(err))
                    @test accepted[] == 1
                else
                    # prefer retries on a fresh connection without GSS
                    @test err === nothing
                    @test accepted[] == 2
                end
            end
        end
    end

    @testset "GSS handshake failures after G" begin
        # server replies to the first token with a plain ErrorResponse
        for mode in ("require", "prefer")
            style = FakeGSSStyle()
            handler = function (sock, n)
                code, _ = read_request(sock)
                if n == 1
                    send(sock, [UInt8('G')])
                    readframe(sock) == FAKE_CLIENT_TOKEN || error("bad client token")
                    send(sock, error_msg("injected mid-handshake text"))
                    return
                end
                send(sock, [UInt8('N')])
                read_startup(sock)
                ready!(sock)
                drain(sock)
            end
            with_fake_server(handler) do port, accepted
                err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode=mode, style=style))
                if mode == "require"
                    @test err isa Postgres.Error
                    @test err.message == "server sent an error response during GSS encryption exchange"
                    @test !occursin("injected", errtext(err))
                    @test accepted[] == 1
                else
                    @test err === nothing
                    @test accepted[] == 2
                end
                @test style.contexts[1].closed
            end
        end
        # server replies with a token the mechanism rejects
        style = FakeGSSStyle()
        handler = function (sock, n)
            read_request(sock)
            send(sock, [UInt8('G')])
            readframe(sock)
            writeframe(sock, Vector{UInt8}("not-the-server-token"))
            drain(sock)
        end
        with_fake_server(handler) do port, accepted
            err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode="require", style=style))
            @test err isa GSSAPI.GSSError
            @test occursin("bad server token", errtext(err))
        end
        # oversize packet on the established transport
        style = FakeGSSStyle()
        handler = function (sock, n)
            read_request(sock)
            send(sock, [UInt8('G')])
            io = server_handshake(sock)
            read_startup(io)
            write(sock, hton(UInt32(20000)))
            flush(sock)
            drain(sock)
        end
        with_fake_server(handler) do port, accepted
            err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode="require", style=style))
            @test err isa Postgres.Error
            @test startswith(err.message, "oversize GSSAPI packet sent by the server")
        end
    end

    @testset "startup error over GSS encryption" begin
        # e.g. a hostgssenc rule that rejects the principal: prefer retries
        # without GSS, require surfaces the (post-handshake) server error
        for mode in ("require", "prefer")
            style = FakeGSSStyle()
            handler = function (sock, n)
                code, _ = read_request(sock)
                if n == 1
                    send(sock, [UInt8('G')])
                    io = server_handshake(sock)
                    read_startup(io)
                    send(io, error_msg("no pg_hba.conf entry for gss"))
                    return
                end
                send(sock, [UInt8('N')])
                read_startup(sock)
                ready!(sock)
                drain(sock)
            end
            with_fake_server(handler) do port, accepted
                err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode=mode, style=style))
                if mode == "require"
                    @test err isa Postgres.Error
                    @test err.code == "28000"
                    @test accepted[] == 1
                else
                    @test err === nothing
                    @test accepted[] == 2
                end
            end
        end
    end

    @testset "no credential cache" begin
        # prefer: GSS is not even attempted; require: fails before dialing
        style = FakeGSSStyle(false)
        handler = function (sock, n)
            code, _ = read_request(sock)
            code == SSL_REQUEST || error("expected SSLRequest, got $code")
            send(sock, [UInt8('N')])
            read_startup(sock)
            ready!(sock)
            drain(sock)
        end
        with_fake_server(handler) do port, accepted
            conn = Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode="prefer", style=style)
            @test conn.socket.transport isa Postgres.Reseau.TCP.Conn
            close(conn)
            err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode="require", style=style))
            @test err isa Postgres.Error
            @test err.message == "GSSAPI encryption required but no credential cache"
            @test accepted[] == 1
            @test isempty(style.contexts)
        end
        @test_throws Postgres.Error Postgres.Connection(host="127.0.0.1", port=1, user="u", gssencmode="bogus", style=style)
    end

    @testset "GSSAPI authentication (codes 7, 8, 9)" begin
        for (code, password) in ((7, nothing), (9, nothing), (7, "unused"))
            style = FakeGSSStyle()
            handler = function (sock, n)
                read_startup(sock)
                send(sock, auth_msg(code))
                mt, body = read_message(sock)
                (mt == 'p' && body == FAKE_CLIENT_TOKEN) || error("expected GSSResponse with the client token, got $mt $(String(copy(body)))")
                send(sock, auth_msg(8, FAKE_SERVER_TOKEN))
                ready!(sock)
                drain(sock)
            end
            with_fake_server(handler) do port, accepted
                conn = Postgres.Connection(host="127.0.0.1", port=port, user="krbuser", password=password, sslmode="disable",
                                           krbsrvname="postgres", gssdelegation=true, style=style)
                @test isopen(conn)
                @test conn.socket.transport isa Postgres.Reseau.TCP.Conn
                @test length(style.contexts) == 1
                @test style.contexts[1].target == "postgres@127.0.0.1"
                @test !style.contexts[1].encrypt && style.contexts[1].delegate
                @test style.contexts[1].closed
                close(conn)
            end
        end
        # AuthenticationOk before the context completed means the server was never authenticated
        style = FakeGSSStyle()
        handler = function (sock, n)
            read_startup(sock)
            send(sock, auth_msg(7))
            read_message(sock)
            ready!(sock)
            drain(sock)
        end
        with_fake_server(handler) do port, accepted
            err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", sslmode="disable", style=style))
            @test err isa Postgres.Error
            @test err.message == "AuthenticationOk received before the GSSAPI context completed"
        end
        # the server rejects the token
        style = FakeGSSStyle()
        handler = function (sock, n)
            read_startup(sock)
            send(sock, auth_msg(7))
            read_message(sock)
            send(sock, error_msg("GSSAPI authentication failed for user \"u\""))
        end
        with_fake_server(handler) do port, accepted
            err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", sslmode="disable", style=style))
            @test err isa Postgres.Error
            @test err.code == "28000" && err.message == "GSSAPI authentication failed for user \"u\""
            @test style.contexts[1].closed
        end
        # a continuation outside the exchange, and a GSS request on an already GSS-encrypted connection
        style = FakeGSSStyle()
        handler = function (sock, n)
            if n == 1
                read_startup(sock)
                send(sock, auth_msg(8, FAKE_SERVER_TOKEN))
            else
                read_request(sock)
                send(sock, [UInt8('G')])
                io = server_handshake(sock)
                read_startup(io)
                send(io, auth_msg(7))
                drain(io)
            end
        end
        with_fake_server(handler) do port, accepted
            err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", sslmode="disable", style=style))
            @test err isa Postgres.Error && err.message == "unexpected GSSAPI continuation message"
            err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", gssencmode="require", style=style))
            @test err isa Postgres.Error && err.message == "duplicate GSS authentication request"
        end
    end

    @testset "SSLRequest error response text is never shown" begin
        handler = function (sock, n)
            code, _ = read_request(sock)
            code == SSL_REQUEST || error("expected SSLRequest, got $code")
            send(sock, vcat(UInt8('E'), error_msg("injected pre-auth text")[2:end]))
        end
        with_fake_server(handler) do port, accepted
            err = connect_err(() -> Postgres.Connection(host="127.0.0.1", port=port, user="u", sslmode="require"))
            @test err isa Postgres.Error
            @test err.message == "server sent an error response during SSL exchange"
            @test !occursin("injected", errtext(err))
        end
    end
end
end

# ── Real Kerberos round trip ──
# An MIT KDC runs inside the PostgreSQL container (the stock image links
# libgssapi_krb5 already; the KDC packages are installed at start). The
# container exports the server keytab and a ticket cache for `krbuser`
# through a mounted directory, and the host client is pointed at them with
# KRB5_CONFIG / KRB5CCNAME, so the driver talks to the KDC and the server
# through the operating system's Kerberos library exactly as a user would.
const KRB_REALM = "EXAMPLE.COM"
const KRB_USER = "krbuser"

function kerberos_postgres_command()
    setup_script = """
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends krb5-kdc krb5-admin-server krb5-user >/dev/null
cat > /etc/krb5.conf <<'KRB'
[libdefaults]
    default_realm = $KRB_REALM
    dns_lookup_kdc = false
    dns_lookup_realm = false
    dns_canonicalize_hostname = false
    rdns = false
[realms]
    $KRB_REALM = {
        kdc = 127.0.0.1:88
    }
KRB
mkdir -p /etc/krb5kdc /var/lib/krb5kdc
cat > /etc/krb5kdc/kdc.conf <<'KDC'
[kdcdefaults]
    kdc_listen = 0.0.0.0:88
    kdc_tcp_listen = 0.0.0.0:88
[realms]
    $KRB_REALM = {
        database_name = /var/lib/krb5kdc/principal
        key_stash_file = /etc/krb5kdc/stash
        max_life = 10h 0m 0s
    }
KDC
# the mounted directory is only traversable by root (it is a 0700 host temp
# dir on Linux), so the server's files live in a container-local directory
# and only the ticket cache goes out through the mount
mkdir -p /etc/pgkrb
cp /keys/pg_hba.conf /etc/pgkrb/pg_hba.conf
kdb5_util create -s -P master-secret -r $KRB_REALM >/dev/null
kadmin.local -q "addprinc -randkey postgres/127.0.0.1@$KRB_REALM" >/dev/null
kadmin.local -q "ktadd -k /etc/pgkrb/server.keytab postgres/127.0.0.1@$KRB_REALM" >/dev/null
kadmin.local -q "addprinc -pw user-secret $KRB_USER@$KRB_REALM" >/dev/null
krb5kdc
echo user-secret | kinit -c /keys/ccache $KRB_USER@$KRB_REALM
chmod 644 /keys/ccache
chown postgres:postgres /etc/pgkrb/server.keytab /etc/pgkrb/pg_hba.conf
chmod 600 /etc/pgkrb/server.keytab
exec docker-entrypoint.sh postgres -c krb_server_keyfile=/etc/pgkrb/server.keytab -c hba_file=/etc/pgkrb/pg_hba.conf
"""
    return ["sh", "-c", setup_script]
end

function with_kerberos_postgres(f::Function)
    image, tag = parse_image_ref(IMAGE_REF)
    host_port = pick_port()
    kdc_port = pick_port()
    env = Dict(
        "POSTGRES_USER" => DEFAULT_USER,
        "POSTGRES_PASSWORD" => DEFAULT_PASSWORD,
        "POSTGRES_DB" => DEFAULT_DB,
        "POSTGRES_HOST_AUTH_METHOD" => DEFAULT_AUTH,
        "POSTGRES_INITDB_ARGS" => DEFAULT_INITDB_ARGS,
    )
    mktempdir(@__DIR__) do dir
        # the principal is `postgres/127.0.0.1`, so the client must dial that host
        write(joinpath(dir, "pg_hba.conf"), """
local all all trust
hostgssenc all $KRB_USER 0.0.0.0/0 gss include_realm=0 krb_realm=$KRB_REALM
hostnogssenc all $KRB_USER 0.0.0.0/0 gss include_realm=0 krb_realm=$KRB_REALM
host all all 0.0.0.0/0 trust
host all all ::/0 trust
""")
        # Only TCP is published: MIT forces TCP with udp_preference_limit = 0,
        # Heimdal (macOS) with the tcp/ prefix.
        kdc = Sys.isapple() ? "tcp/127.0.0.1:$kdc_port" : "127.0.0.1:$kdc_port"
        write(joinpath(dir, "krb5.conf"), """
[libdefaults]
    default_realm = $KRB_REALM
    dns_lookup_kdc = false
    dns_lookup_realm = false
    dns_canonicalize_hostname = false
    rdns = false
    udp_preference_limit = 0
[realms]
    $KRB_REALM = {
        kdc = $kdc
    }
""")
        Harbor.with_container(
            image;
            tag=tag,
            ports=Dict(5432 => host_port, 88 => kdc_port),
            volumes=Dict("/keys" => dir),
            environment=env,
            command=kerberos_postgres_command(),
            wait_strategy=(pattern="database system is ready to accept connections",),
            wait_timeout=300.0,
            container_logs_on_error=true,
        ) do _
            cfg = PgConfig("127.0.0.1", host_port, DEFAULT_USER, DEFAULT_PASSWORD, DEFAULT_DB)
            withenv("KRB5_CONFIG" => joinpath(dir, "krb5.conf"), "KRB5CCNAME" => "FILE:" * joinpath(dir, "ccache")) do
                return f(cfg)
            end
        end
    end
end

gss_status(conn) = only(Tables.rowtable(DBInterface.execute(conn,
    "SELECT gss_authenticated, encrypted, principal FROM pg_stat_gssapi WHERE pid = pg_backend_pid()")))

function test_kerberos_integration()
    @testset "Kerberos Fixture" begin
        with_kerberos_postgres() do cfg
            admin = wait_for_connection(cfg)
            try
                DBInterface.execute(admin, "DROP ROLE IF EXISTS $KRB_USER")
                DBInterface.execute(admin, "CREATE ROLE $KRB_USER LOGIN")
                @test GSSAPI.has_credentials()

                # GSSAPI authentication on a plain connection (hostnogssenc rule)
                auth_conn = DBInterface.connect(Postgres.Connection, cfg.host, KRB_USER, nothing; dbname=cfg.dbname, port=cfg.port, sslmode="disable")
                try
                    @test auth_conn.socket.transport isa Postgres.Reseau.TCP.Conn
                    status = gss_status(auth_conn)
                    @test status.gss_authenticated && !status.encrypted
                    @test status.principal == "$KRB_USER@$KRB_REALM"
                finally
                    DBInterface.close!(auth_conn)
                end

                # GSSAPI encryption (hostgssenc rule): the token exchange is skipped
                # and the principal is checked from the encrypted transport
                for mode in ("require", "prefer")
                    enc_conn = DBInterface.connect(Postgres.Connection, cfg.host, KRB_USER, nothing; dbname=cfg.dbname, port=cfg.port, gssencmode=mode)
                    try
                        @test enc_conn.socket.transport isa Postgres.API.GSSConn
                        status = gss_status(enc_conn)
                        @test status.gss_authenticated && status.encrypted
                        @test status.principal == "$KRB_USER@$KRB_REALM"
                        # results larger than one GSS packet are reassembled
                        big = only(DBInterface.execute(enc_conn, "SELECT repeat('x', 100000) AS s")).s
                        @test length(big) == 100000
                        # parameters larger than one packet are chunked on the way out
                        echoed = only(DBInterface.execute(enc_conn, "SELECT length(\$1::text) AS n", (repeat("y", 70000),))).n
                        @test echoed == 70000
                        if mode == "require"
                            cancel_task = errormonitor(Threads.@spawn begin
                                try
                                    DBInterface.execute(enc_conn, "SELECT pg_sleep(5)")
                                    :completed
                                catch err
                                    err
                                end
                            end)
                            sleep(0.5)
                            Postgres.cancel_query!(enc_conn)
                            cancel_result = fetch(cancel_task)
                            @test cancel_result isa Postgres.API.Error
                            @test cancel_result.code == "57014"
                        end
                    finally
                        DBInterface.close!(enc_conn)
                    end
                end

                # a service principal the KDC does not know fails cleanly
                err = connect_err(() -> DBInterface.connect(Postgres.Connection, cfg.host, KRB_USER, nothing; dbname=cfg.dbname, port=cfg.port, gssencmode="require", krbsrvname="nosuchservice"))
                @test err isa GSSAPI.GSSError
                @test occursin("could not initiate GSSAPI security context", errtext(err))
                # ... and prefer falls back to a plain connection, which the
                # hostnogssenc rule then authenticates with a token exchange
                # against the same unknown principal, so it fails too
                err = connect_err(() -> DBInterface.connect(Postgres.Connection, cfg.host, KRB_USER, nothing; dbname=cfg.dbname, port=cfg.port, gssencmode="prefer", krbsrvname="nosuchservice"))
                @test err isa GSSAPI.GSSError
            finally
                DBInterface.execute(admin, "DROP ROLE IF EXISTS $KRB_USER")
                DBInterface.close!(admin)
            end
        end
    end
end

function test_gss_fragmentation()
    @testset "GSS validation preserves incomplete frames" begin
        for completion in (:read, :validation)
            finish = Base.Event()
            sent = Channel{Int}(1)
            advance = Channel{Nothing}(1)
            message = pgmsg('A', vcat(be32(77), Vector{UInt8}("gss-fragments"), 0x00, Vector{UInt8}("retained"), 0x00))
            message = vcat(param_status("application_name", "fragmented-gss"), message)
            token = vcat(FAKE_SEAL, message)
            frame = vcat(be32(length(token)), token)
            handler = function(sock, n)
                code, _ = read_request(sock)
                code == GSSENC_REQUEST || error("expected GSS request")
                send(sock, UInt8['G'])
                io = server_handshake(sock)
                read_startup(io)
                ready!(io)
                start = 1
                for stop in (1, 3, 4, length(frame)-1)
                    send(sock, frame[start:stop])
                    put!(sent, stop)
                    take!(advance)
                    start = stop + 1
                end
                send(sock, frame[start:end])
                wait(finish)
                close(sock)
            end
            with_fake_server(handler) do port, accepted
                conn = Postgres.Connection(host="127.0.0.1", port=port, user="u", dbname="db", gssencmode="require", style=FakeGSSStyle())
                try
                    for _ in 1:4
                        stop = take!(sent)
                        @test !eof(conn.socket.transport.tcp)
                        @test Postgres.isvalid(conn)
                        @test conn.socket.transport.received == stop
                        @test bytesavailable(conn.socket) == 0
                        put!(advance, nothing)
                    end
                    if completion == :read
                        notification = Postgres.wait_for_notification(conn; timeout=5)
                        @test notification !== nothing
                        @test notification.channel == "gss-fragments"
                        @test notification.payload == "retained"
                    else
                        @test !eof(conn.socket.transport.tcp)
                        @test Postgres.isvalid(conn)
                    end
                    @test Postgres.get_server_parameter(conn, "application_name") == "fragmented-gss"
                    notify(finish)
                    @test eof(conn.socket.transport.tcp)
                    @test !Postgres.isvalid(conn)
                finally
                    notify(finish)
                    close(conn)
                end
            end
        end
    end
    test_gss_read_budget()
end

function test_gss_read_budget()
    @testset "GSS nonblocking record budget" begin
        for (empty_frames, shared_buffer) in ((15, true), (15, false), (16, false))
            finish = Base.Event()
            sent = Channel{Nothing}(1)
            message = pgmsg('A', vcat(be32(77), UInt8['c', 0, 'p', 0]))
            empty_frame = vcat(be32(1), FAKE_SEAL)
            token = vcat(FAKE_SEAL, message)
            wire = vcat(repeat(empty_frame, empty_frames), be32(length(token)), token)
            handler = function(sock, n)
                read_request(sock)
                send(sock, UInt8['G'])
                io = server_handshake(sock)
                read_startup(io)
                ready!(io)
                send(sock, wire)
                put!(sent, nothing)
                wait(finish)
            end
            with_fake_server(handler) do port, accepted
                conn = Postgres.Connection(host="127.0.0.1", port=port, user="u", dbname="db",
                                           gssencmode="require", style=FakeGSSStyle())
                transport = conn.socket.transport
                buf = zeros(UInt8, 3)
                try
                    take!(sent)
                    deadline = time_ns() + UInt64(5_000_000_000)
                    Postgres.API.set_read_deadline!(transport, deadline)
                    @test !eof(transport.tcp)
                    # No other reader uses this socket. Wait for the full fixture,
                    # since readability alone only guarantees its first byte.
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
                    Postgres.API.set_read_deadline!(transport, 0)
                    @test peeked == wire
                    n = shared_buffer ? Postgres.API.consume_input!(conn.socket) : Postgres.API.tryread!(transport, buf)
                    expected = empty_frames == 16 ? nothing : shared_buffer ? length(message) : length(buf)
                    @test n === expected
                    if empty_frames == 16
                        @test bytesavailable(transport) == 0
                        @test !eof(transport.tcp) # The seventeenth record was not consumed.
                    end
                    if n === nothing
                        n = shared_buffer ? Postgres.API.consume_input!(conn.socket) : Postgres.API.tryread!(transport, buf)
                    end
                    if shared_buffer
                        @test n == length(message)
                        @test conn.socket.buffer == message
                    else
                        @test n == length(buf)
                        received = copy(buf[1:n])
                        @test bytesavailable(transport) == length(message) - n
                        @test Postgres.API.Reseau.TCP.tryread!(transport.tcp, zeros(UInt8, 1)) === nothing
                        while length(received) < length(message)
                            n = Postgres.API.tryread!(transport, buf)
                            @test n isa Int && n > 0
                            append!(received, @view(buf[1:n]))
                        end
                        @test received == message
                    end
                    @test bytesavailable(transport) == 0
                    @test Postgres.API.tryread!(transport, buf) === nothing
                    notify(finish)
                    @test eof(transport.tcp)
                    @test Postgres.API.tryread!(transport, buf) == 0
                finally
                    notify(finish)
                    close(conn)
                end
            end
        end
    end
end
