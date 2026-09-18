# GSSAPI (Kerberos) support: the authentication token exchange (auth codes 7,
# 8, 9 and the GSSResponse message) and the GSS-encrypted transport
# (GSSENCRequest, then every message gss_wrap'ed and framed with a 4-byte
# length). The mechanism itself is SASLAuth.GSSAPI, which drives the system
# Kerberos library exactly as libpq does. Message flow, limits, and error
# texts mirror libpq's fe-auth.c and fe-secure-gssapi.c.

const GSSENC_REQUEST_CODE = Int32(80877104)
# PQ_GSS_MAX_PACKET_SIZE: the server rejects larger encrypted packets
const GSS_MAX_PACKET_SIZE = 16384
# PQ_GSS_AUTH_BUFFER_SIZE: handshake tokens (before the transport is up)
const GSS_AUTH_BUFFER_SIZE = 65536

# The GSSAPI mechanism seam: gss_context(style, target, delegate, encrypt) and
# gss_has_credentials(style). The defaults use the system Kerberos library
# through SASLAuth.GSSAPI; overload on a custom AbstractPostgresStyle to supply
# a context factory or credential policy. Encrypted connections use Context.
gss_context(::AbstractPostgresStyle, target::String, delegate::Bool, encrypt::Bool) =
    SASLAuth.GSSAPI.Context(target; delegate, encrypt)
gss_has_credentials(::AbstractPostgresStyle) = SASLAuth.GSSAPI.has_credentials()

# "<krbsrvname>@<host>", GSS_C_NT_HOSTBASED_SERVICE, as pg_GSS_load_servicename builds it
function gss_target(host::String, krbsrvname::String)
    isempty(host) && throw(Error("host name must be specified"))
    return string(krbsrvname, "@", host)
end

# A GSS-encrypted PostgreSQL transport over a TCP connection: every write is
# gss_wrap'ed in chunks and framed as a 4-byte network-order length plus the
# sealed token; reads unwrap one frame at a time into a plaintext buffer.
mutable struct GSSConn <: IO
    tcp::Reseau.TCP.Conn
    ctx::SASLAuth.GSSAPI.Context
    max_plaintext::Int      # gss_wrap_size_limit for one packet
    buffer::Vector{UInt8}   # unwrapped plaintext not yet consumed
    pos::Int
end

function _write_framed(tcp::Reseau.TCP.Conn, token::Vector{UInt8})
    write(tcp, hton(UInt32(length(token))))
    write(tcp, token)
    flush(tcp)
    return
end

# During the handshake the server may answer a token with a plain ErrorResponse
# instead of a framed token; its first byte is 'E' where a length's first byte
# is always zero. As with SSLRequest, the text is not shown: the server is not
# authenticated yet (CVE-2024-10977).
function _read_framed(socket, max_len::Int, debug::Bool)
    header = read(socket, 4)
    length(header) == 4 || throw(EOFError())
    header[1] == UInt8('E') && close_and_throw(socket, Error("server sent an error response during GSS encryption exchange"))
    len = Int(ntoh(reinterpret(UInt32, header)[1]))
    len > max_len && close_and_throw(socket, Error("oversize GSSAPI packet sent by the server ($len > $max_len)"))
    debug && @info "received GSSAPI packet ($len bytes)"
    return read!(socket, Vector{UInt8}(undef, len))
end

function _fill!(io::GSSConn)
    # a read failure here leaves the transport where it was: a read-deadline
    # expiry on the first header byte (wait_for_notification polling) consumes
    # nothing, and callers close the connection on every other failure
    token = _read_framed(io.tcp, GSS_MAX_PACKET_SIZE - 4, false)
    io.buffer = try
        SASLAuth.GSSAPI.unwrap(io.ctx, token)
    catch
        close(io)
        rethrow()
    end
    io.pos = 1
    return
end

Base.bytesavailable(io::GSSConn) = length(io.buffer) - io.pos + 1
Base.isopen(io::GSSConn) = isopen(io.tcp)
Base.eof(io::GSSConn) = bytesavailable(io) > 0 ? false : eof(io.tcp)
Base.flush(io::GSSConn) = flush(io.tcp)
function Base.close(io::GSSConn)
    close(io.tcp)
    close(io.ctx)
    return
end

function Base.read(io::GSSConn, ::Type{UInt8})
    while bytesavailable(io) == 0
        _fill!(io)
    end
    b = @inbounds io.buffer[io.pos]
    io.pos += 1
    return b
end

function Base.unsafe_read(io::GSSConn, p::Ptr{UInt8}, n::UInt)
    remaining = Int(n)
    offset = 0
    while remaining > 0
        avail = bytesavailable(io)
        if avail == 0
            _fill!(io)
            continue
        end
        k = min(avail, remaining)
        GC.@preserve io unsafe_copyto!(p + offset, pointer(io.buffer, io.pos), k)
        io.pos += k
        offset += k
        remaining -= k
    end
    return nothing
end

function Base.readbytes!(io::GSSConn, buf::AbstractVector{UInt8}, nb::Integer=length(buf); all::Bool=true)
    n = Int(nb)
    if !all
        while bytesavailable(io) == 0
            _fill!(io)
        end
        n = min(n, bytesavailable(io))
    end
    length(buf) < n && resize!(buf, n)
    GC.@preserve buf unsafe_read(io, pointer(buf), UInt(n))
    return n
end

function Base.unsafe_write(io::GSSConn, p::Ptr{UInt8}, n::UInt)
    remaining = Int(n)
    offset = 0
    while remaining > 0
        k = min(remaining, io.max_plaintext)
        token = SASLAuth.GSSAPI.wrap(io.ctx, unsafe_wrap(Array, p + offset, k))
        length(token) > GSS_MAX_PACKET_SIZE - 4 &&
            close_and_throw(io, Error("client tried to send oversize GSSAPI packet ($(length(token)) > $(GSS_MAX_PACKET_SIZE - 4))"))
        _write_framed(io.tcp, token)
        offset += k
        remaining -= k
    end
    return Int(n)
end

set_read_deadline!(io::GSSConn, deadline_ns::Integer) = Reseau.TCP.set_read_deadline!(io.tcp, deadline_ns)

# GSSENCRequest and, on 'G', the framed handshake (libpq's pqsecure_open_gss).
# Returns the encrypted transport, or `nothing` when the server answered 'N'
# (the caller decides whether that is acceptable and continues on the same
# socket). 'E' is a hard failure whose text is never shown.
function gss_encrypt(socket::Reseau.TCP.Conn, style::AbstractPostgresStyle, host::String, krbsrvname::String,
                     delegate::Bool, debug::Bool)
    writemessage(socket, debug, '\0', GSSENC_REQUEST_CODE)
    mt = read(socket, UInt8)
    if mt == UInt8('E')
        close_and_throw(socket, Error("server sent an error response during GSS encryption exchange"))
    elseif mt == UInt8('N')
        return nothing
    elseif mt != UInt8('G')
        close_and_throw(socket, Error("received invalid response to GSSAPI negotiation: $(Char(mt))"))
    end
    ctx = gss_context(style, gss_target(host, krbsrvname), delegate, true)
    try
        token = nothing
        while true
            out, done = SASLAuth.GSSAPI.step!(ctx, token)
            if !isempty(out)
                length(out) > GSS_AUTH_BUFFER_SIZE - 4 &&
                    close_and_throw(socket, Error("client tried to send oversize GSSAPI packet ($(length(out)) > $(GSS_AUTH_BUFFER_SIZE - 4))"))
                debug && @info "sending GSSAPI handshake token ($(length(out)) bytes)"
                _write_framed(socket, out)
            end
            done && break
            token = _read_framed(socket, GSS_AUTH_BUFFER_SIZE - 4, debug)
        end
        max_plaintext = SASLAuth.GSSAPI.wrap_size_limit(ctx, GSS_MAX_PACKET_SIZE - 4)
        max_plaintext > 0 || close_and_throw(socket, Error("GSSAPI size check error: no room for data in a $(GSS_MAX_PACKET_SIZE)-byte packet"))
        return GSSConn(socket, ctx, max_plaintext, UInt8[], 1)
    catch
        close(ctx)
        rethrow()
    end
end

# Authentication codes 7 (GSS) and 9 (SSPI, handled with the GSSAPI library as a
# Unix libpq does): send GSSResponse tokens until the context completes, feeding
# back each code-8 continuation. AuthenticationOk before the context completed
# would mean the server was never authenticated (mutual auth), so it is refused.
function gss_authenticate!(socket, style::AbstractPostgresStyle, host::String, krbsrvname::String, delegate::Bool, debug::Bool)
    socket isa GSSConn && close_and_throw(socket, Error("duplicate GSS authentication request"))
    ctx = gss_context(style, gss_target(host, krbsrvname), delegate, false)
    try
        token = nothing
        while true
            out, done = SASLAuth.GSSAPI.step!(ctx, token)
            if !isempty(out)
                debug && @info "sending message: p, (GSSAPI token redacted)"
                writemessage(socket, false, 'p', out)
            end
            mt, len = readheader(socket, debug, MAX_PREAUTH_MESSAGE_LEN)
            expect_auth_message(socket, debug, mt, len)
            code = ntoh(read(socket, Int32))
            debug && @info "auth code: $code"
            if code == 0
                done || close_and_throw(socket, Error("AuthenticationOk received before the GSSAPI context completed"))
                return
            elseif code == 8
                token = read(socket, len - 4)
            else
                close_and_throw(socket, Error("unexpected authentication code $code during GSSAPI authentication"))
            end
        end
    finally
        close(ctx)
    end
end
