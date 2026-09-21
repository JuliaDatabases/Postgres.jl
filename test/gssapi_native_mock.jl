# Test-only native entry points. Production and tests both use GSSAPI.Context;
# only symbol lookup is replaced while the scripted protocol tests run.
const FAKE_NAMES = Dict{Ptr{Cvoid}, FakeGSS}()
const FAKE_BUFFERS = Dict{Ptr{UInt8}, Vector{UInt8}}()
const FAKE_CONTEXTS = GSSAPI.Context[]
const FAKE_NEXT_NAME = Ref(UInt(0))
const FAKE_FAILURE = UInt32(0x000d0000)

function fake_bytes(buf)
    b = unsafe_load(buf)
    return b.length == 0 ? UInt8[] : copy(unsafe_wrap(Array, b.value, Int(b.length)))
end
function fake_output(buf, bytes)
    data = Vector{UInt8}(bytes)
    if isempty(data)
        unsafe_store!(buf, GSSAPI.Buffer(0, C_NULL))
    else
        FAKE_BUFFERS[pointer(data)] = data
        unsafe_store!(buf, GSSAPI.Buffer(length(data), pointer(data)))
    end
    return UInt32(0)
end
function fake_import(minor, input, oid, name)
    key = Ptr{Cvoid}(FAKE_NEXT_NAME[] += 1)
    FAKE_NAMES[key] = FakeGSS(String(fake_bytes(input)), false, false, 0, false)
    unsafe_store!(name, key)
    return UInt32(0)
end
function fake_init(minor, cred, handle, target, mech, flags, time, bindings, input, actual, output, retflags, lifetime)
    ctx = FAKE_NAMES[target]
    unsafe_store!(handle, target)
    ctx.delegate = flags & GSSAPI.DELEG_FLAG != 0
    ctx.encrypt = flags & GSSAPI.CONF_FLAG != 0
    token = fake_bytes(input)
    if ctx.state == 0 && isempty(token)
        ctx.state = 1
        fake_output(output, FAKE_CLIENT_TOKEN)
        return UInt32(1)
    elseif ctx.state == 1 && token == FAKE_SERVER_TOKEN
        ctx.state = 2
        fake_output(output, UInt8[])
        return UInt32(0)
    end
    unsafe_store!(minor, UInt32(1))
    return FAKE_FAILURE
end
function fake_wrap(minor, handle, request, qop, input, conf, output)
    FAKE_NAMES[handle].state == 2 || return FAKE_FAILURE
    unsafe_store!(conf, Cint(1))
    return fake_output(output, vcat(FAKE_SEAL, fake_bytes(input)))
end
function fake_unwrap(minor, handle, input, output, conf, qop)
    token = fake_bytes(input)
    (!isempty(token) && token[1] == FAKE_SEAL) || return FAKE_FAILURE
    unsafe_store!(conf, Cint(1))
    return fake_output(output, token[2:end])
end
function fake_limit(minor, handle, conf, qop, max_output, max_input)
    unsafe_store!(max_input, UInt32(7)) # Force framing into tiny packets.
    return UInt32(0)
end
function fake_release_buffer(minor, buf)
    pop!(FAKE_BUFFERS, unsafe_load(buf).value, nothing)
    unsafe_store!(buf, GSSAPI.Buffer(0, C_NULL))
    return UInt32(0)
end
function fake_delete(minor, handle, output)
    FAKE_NAMES[unsafe_load(handle)].closed = true
    unsafe_store!(handle, Ptr{Cvoid}(C_NULL))
    return UInt32(0)
end
function fake_release_name(minor, name)
    pop!(FAKE_NAMES, unsafe_load(name)).closed = true
    unsafe_store!(name, Ptr{Cvoid}(C_NULL))
    return UInt32(0)
end
function fake_status(minor, code, kind, mech, msgctx, buf)
    unsafe_store!(msgctx, UInt32(0))
    message = kind == GSSAPI.C_MECH_CODE && code == 1 ? b"bad server token" :
              code == 0 ? b"success" : b"fake mechanism failure"
    return fake_output(buf, message)
end

const FAKE_SYMBOLS = Dict(
    :gss_import_name => @cfunction(fake_import, UInt32, (Ptr{UInt32}, Ptr{GSSAPI.Buffer}, Ptr{Cvoid}, Ptr{Ptr{Cvoid}})),
    :gss_init_sec_context => @cfunction(fake_init, UInt32, (Ptr{UInt32}, Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Ptr{Cvoid}, UInt32, UInt32, Ptr{Cvoid}, Ptr{GSSAPI.Buffer}, Ptr{Cvoid}, Ptr{GSSAPI.Buffer}, Ptr{UInt32}, Ptr{UInt32})),
    :gss_wrap => @cfunction(fake_wrap, UInt32, (Ptr{UInt32}, Ptr{Cvoid}, Cint, UInt32, Ptr{GSSAPI.Buffer}, Ptr{Cint}, Ptr{GSSAPI.Buffer})),
    :gss_unwrap => @cfunction(fake_unwrap, UInt32, (Ptr{UInt32}, Ptr{Cvoid}, Ptr{GSSAPI.Buffer}, Ptr{GSSAPI.Buffer}, Ptr{Cint}, Ptr{UInt32})),
    :gss_wrap_size_limit => @cfunction(fake_limit, UInt32, (Ptr{UInt32}, Ptr{Cvoid}, Cint, UInt32, UInt32, Ptr{UInt32})),
    :gss_release_buffer => @cfunction(fake_release_buffer, UInt32, (Ptr{UInt32}, Ptr{GSSAPI.Buffer})),
    :gss_delete_sec_context => @cfunction(fake_delete, UInt32, (Ptr{UInt32}, Ptr{Ptr{Cvoid}}, Ptr{Cvoid})),
    :gss_release_name => @cfunction(fake_release_name, UInt32, (Ptr{UInt32}, Ptr{Ptr{Cvoid}})),
    :gss_display_status => @cfunction(fake_status, UInt32, (Ptr{UInt32}, UInt32, Cint, Ptr{Cvoid}, Ptr{UInt32}, Ptr{GSSAPI.Buffer})),
)

function test_gssapi()
    @eval GSSAPI sym(name::Symbol) = $(FAKE_SYMBOLS)[name]
    try
        Base.invokelatest(test_gssapi_protocol)
        Base.invokelatest(test_gss_fragmentation)
    finally
        # Close even contexts left behind by a failed test before restoring the
        # real library; a finalizer must never hand a fake handle to Kerberos.
        try
            for ctx in FAKE_CONTEXTS
                Base.invokelatest(close, ctx)
            end
            empty!(FAKE_CONTEXTS)
        finally
            @eval GSSAPI sym(name::Symbol) = dlsym(library(), name)
        end
    end
    @test isempty(FAKE_NAMES)
    @test isempty(FAKE_BUFFERS)
end
