# Validation and ordinary protocol reads share this buffer. Only the owning
# Connection's lock may read from it or collect more transport input.
const Transport = Union{Reseau.TCP.Conn, Reseau.TLS.Conn, GSSConn}
mutable struct BufferedConn <: IO
    transport::Transport
    buffer::Vector{UInt8}
    pos::Int
    ended::Bool
    scratch::Vector{UInt8}
end
BufferedConn(io::Transport) = BufferedConn(io, UInt8[], 1, false, Vector{UInt8}(undef, 8192))

Base.isopen(io::BufferedConn) = isopen(io.transport)
Base.close(io::BufferedConn) = close(io.transport)
Base.flush(io::BufferedConn) = flush(io.transport)
Base.bytesavailable(io::BufferedConn) = length(io.buffer) - io.pos + 1
Base.eof(io::BufferedConn) = bytesavailable(io) == 0 && (io.ended || eof(io.transport))
Base.unsafe_write(io::BufferedConn, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.transport, p, n)

# Protocol fields are read a few bytes at a time and the transports read the
# socket on every call, so take whatever one transport read returns (up to the
# scratch size) into the buffer. Returns false at EOF.
function fill_buffer!(io::BufferedConn)::Bool
    io.ended && return false
    if io.pos > 1
        deleteat!(io.buffer, 1:io.pos-1)
        io.pos = 1
    end
    n = readbytes!(io.transport, io.scratch, length(io.scratch); all=false)
    n == 0 && (io.ended = true; return false)
    append!(io.buffer, @view(io.scratch[1:n]))
    return true
end

function Base.read(io::BufferedConn, ::Type{UInt8})
    bytesavailable(io) > 0 || fill_buffer!(io) || throw(EOFError())
    b = io.buffer[io.pos]
    io.pos += 1
    return b
end

function Base.unsafe_read(io::BufferedConn, p::Ptr{UInt8}, n::UInt)
    remaining = Int(n)
    while remaining > 0
        if bytesavailable(io) == 0
            # a remainder larger than the scratch buffer goes straight to `p`
            if remaining >= length(io.scratch) && !io.ended
                unsafe_read(io.transport, p, UInt(remaining))
                return nothing
            end
            fill_buffer!(io) || throw(EOFError())
        end
        k = min(remaining, bytesavailable(io))
        GC.@preserve io unsafe_copyto!(p, pointer(io.buffer, io.pos), k)
        io.pos += k
        p += k
        remaining -= k
    end
    return nothing
end

function Base.readbytes!(io::BufferedConn, buf::AbstractVector{UInt8}, nb::Integer=length(buf); all::Bool=true)
    n = Int(nb)
    n >= 0 || throw(ArgumentError("nb must be nonnegative"))
    length(buf) < n && resize!(buf, n)
    total = 0
    while total < n
        if bytesavailable(io) == 0
            if n - total >= length(io.scratch) && !io.ended
                return total + readbytes!(io.transport, @view(buf[total+1:n]), n-total; all)
            end
            fill_buffer!(io) || break
        end
        k = min(n - total, bytesavailable(io))
        copyto!(buf, total + 1, io.buffer, io.pos, k)
        io.pos += k
        total += k
        all || break
    end
    return total
end

# Collect at most one scratch buffer per call. Partial messages stay here,
# including when validation stops before all currently available bytes drain.
function consume_input!(io::BufferedConn)::Union{Int, Nothing}
    io.ended && return 0
    if io.pos > 1
        deleteat!(io.buffer, 1:io.pos-1)
        io.pos = 1
    end
    transport = io.transport
    n = if transport isa Reseau.TCP.Conn
        Reseau.TCP.tryread!(transport, io.scratch)
    elseif transport isa Reseau.TLS.Conn
        Reseau.TLS.tryread!(transport, io.scratch)
    else
        tryread!(transport::GSSConn, io.scratch)
    end
    if n !== nothing
        n == 0 ? (io.ended = true) : append!(io.buffer, @view(io.scratch[1:n]))
    end
    return n
end

# Claim only a complete PostgreSQL message. Parse the returned view before
# collecting more input, which may compact or resize the shared buffer.
function take_frame!(io::BufferedConn)
    bytesavailable(io) >= 5 || return nothing
    pos = io.pos
    len = Int(ntoh(reinterpret(Int32, @view(io.buffer[pos+1:pos+4]))[1])) - 4
    (0 <= len <= MAX_MESSAGE_LEN) || throw(Error("invalid message length from server"))
    bytesavailable(io) >= 5 + len || return nothing
    frame = IOBuffer(@view(io.buffer[pos:pos+4+len]))
    io.pos += 5 + len
    return frame
end

# On failure, abort TCP first: TLS close must not wait to send close_notify.
function abort(io::BufferedConn)
    transport = io.transport
    transport isa Reseau.TLS.Conn && close(transport.tcp)
    close(transport)
    return nothing
end
