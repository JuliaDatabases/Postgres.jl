module ConnectionString

using URIs

"""
    Postgres.ConnectionParams(; host="localhost", port=5432, user="", password=nothing,
                              dbname="", kwargs...)

Structured connection options, an alternative to DSN strings:

    params = Postgres.ConnectionParams(host="127.0.0.1", user="postgres", dbname="postgres")
    conn = DBInterface.connect(Postgres.Connection, params)

Also produced by `Postgres.parse_dsn`. Supported keyword
arguments mirror the connection keywords: `application_name`, `options`,
`connect_timeout`, `sslmode`, `sslrootcert`, `sslcert`, `sslkey`, `sslcapath`,
`sslservername`, `gssencmode`, `krbsrvname`, `gssdelegation`,
`statement_timeout`, `statement_cache_maxsize`, `debug`, and `reconnect`. `numeric_overflow` accepts `:warn` (return out-of-range numeric
values as text with a warning) or `:error` (throw). DSN strings use `warn` or
`error` without the colon.
"""
struct ConnectionParams
    host::String
    port::Int
    user::String
    password::Union{String, Nothing}
    dbname::String
    application_name::Union{String, Nothing}
    options::Union{String, Nothing}
    connect_timeout::Union{Int, Nothing}
    sslmode::Union{String, Nothing}
    sslrootcert::Union{String, Nothing}
    sslcert::Union{String, Nothing}
    sslkey::Union{String, Nothing}
    sslcapath::Union{String, Nothing}
    sslservername::Union{String, Nothing}
    gssencmode::Union{String, Nothing}
    krbsrvname::Union{String, Nothing}
    gssdelegation::Bool
    statement_timeout::Union{Int, Nothing}
    statement_cache_maxsize::Int
    debug::Bool
    reconnect::Bool
    numeric_overflow::Symbol
end

function ConnectionParams(; host::String="localhost", port::Int=5432, user::String="", password::Union{String, Nothing}=nothing, dbname::String="", application_name::Union{String, Nothing}=nothing, options::Union{String, Nothing}=nothing, connect_timeout::Union{Int, Nothing}=nothing, sslmode::Union{String, Nothing}=nothing, sslrootcert::Union{String, Nothing}=nothing, sslcert::Union{String, Nothing}=nothing, sslkey::Union{String, Nothing}=nothing, sslcapath::Union{String, Nothing}=nothing, sslservername::Union{String, Nothing}=nothing, gssencmode::Union{String, Nothing}=nothing, krbsrvname::Union{String, Nothing}=nothing, gssdelegation::Bool=false, statement_timeout::Union{Int, Nothing}=nothing, statement_cache_maxsize::Int=100, debug::Bool=false, reconnect::Bool=false, numeric_overflow::Symbol=:warn)
    numeric_overflow in (:warn, :error) || throw(ArgumentError("numeric_overflow must be :warn or :error"))
    return ConnectionParams(host, port, user, password, dbname, application_name, options, connect_timeout, sslmode, sslrootcert, sslcert, sslkey, sslcapath, sslservername, gssencmode, krbsrvname, gssdelegation, statement_timeout, statement_cache_maxsize, debug, reconnect, numeric_overflow)
end

function Base.show(io::IO, params::ConnectionParams)
    password = params.password === nothing ? "nothing" : "***"
    print(io, "Postgres.ConnectionParams(host=", repr(params.host),
          ", port=", params.port, ", user=", repr(params.user),
          ", password=", password, ", dbname=", repr(params.dbname), ")")
end
Base.show(io::IO, ::MIME"text/plain", params::ConnectionParams) = show(io, params)

default_user() = get(ENV, "PGUSER", get(ENV, "USER", get(ENV, "USERNAME", "")))

"""
    Postgres.ConnectionParameterError <: Exception

Why a connection string is invalid, as returned by `Postgres.validate_dsn`.

- `key`: the name of the parameter that failed, or `nothing` when there is no
  recognized parameter to name (an unknown or empty key, or a malformed URI).
  It is always a parameter name Postgres.jl supports or accepts and ignores,
  never text taken from a value.
- `reason`: `:unknown_key`, `:invalid_value`, `:unsupported_ignored` (an
  ignored libpq parameter set to a value that cannot be safely ignored), or
  `:malformed` (keyword-string syntax or URI errors).
- `msg`: the message `Postgres.parse_dsn` throws for the same input. Only
  `:invalid_value` messages for integer and boolean parameters include the
  rejected value.
"""
struct ConnectionParameterError <: Exception
    key::Union{String, Nothing}
    reason::Symbol
    msg::String
end
Base.showerror(io::IO, e::ConnectionParameterError) = print(io, e.msg)

# The parsing helpers below return a ConnectionParameterError instead of
# throwing, so validate_dsn can report one without a try/catch and parse_dsn
# throws a fresh ArgumentError with no exception chain that could carry input.
function parse_optional_int(value::Union{String, Nothing}, key::String="")
    value === nothing && return nothing
    isempty(value) && return nothing
    parsed = tryparse(Int, value)
    parsed === nothing && return ConnectionParameterError(key, :invalid_value, "invalid value \"$(escape_string(value))\" for connection parameter \"$key\"; expected an integer")
    return parsed
end

function connection_defaults()
    user = default_user()
    return Dict{String, String}(
        "host" => get(ENV, "PGHOST", "localhost"),
        "port" => get(ENV, "PGPORT", "5432"),
        "user" => user,
        "statement_cache_maxsize" => "100",
    )
end

function apply_env_defaults!(values::Dict{String, String})
    env_map = (
        "dbname" => "PGDATABASE",
        "password" => "PGPASSWORD",
        "application_name" => "PGAPPNAME",
        "options" => "PGOPTIONS",
        "connect_timeout" => "PGCONNECT_TIMEOUT",
        "sslmode" => "PGSSLMODE",
        "sslrootcert" => "PGSSLROOTCERT",
        "sslcert" => "PGSSLCERT",
        "sslkey" => "PGSSLKEY",
        "sslcapath" => "PGSSLCAPATH",
        "gssencmode" => "PGGSSENCMODE",
        "krbsrvname" => "PGKRBSRVNAME",
        "gssdelegation" => "PGGSSDELEGATION",
    )
    for (key, envkey) in env_map
        !haskey(values, key) && haskey(ENV, envkey) && (values[key] = ENV[envkey])
    end
    return values
end

const KNOWN_PARAMS = Set([
    "host", "port", "user", "password", "dbname", "application_name",
    "options", "connect_timeout", "sslmode", "sslrootcert", "sslcert", "sslkey",
    "sslcapath", "sslservername", "gssencmode", "krbsrvname", "gssdelegation",
    "statement_timeout", "statement_cache_maxsize", "debug", "reconnect",
    "numeric_overflow",
])

# libpq keywords this driver doesn't implement. They are accepted and ignored
# rather than rejected: managed-PostgreSQL providers routinely include them in
# the connection URI they hand users, and failing on a DSN that names a real
# libpq option would be worse than not honoring it.
const IGNORED_PARAMS = Set([
    "channel_binding", "target_session_attrs",
    "gsslib", "sslnegotiation", "sslcompression", "sslcrl",
    "sslcrldir", "sslpassword", "requiressl", "requirepeer", "hostaddr",
    "client_encoding", "passfile", "service", "fallback_application_name",
    "keepalives", "keepalives_idle", "keepalives_interval", "keepalives_count",
    "tcp_user_timeout", "load_balance_hosts", "replication",
])

function parse_bool_param(value::Union{String, Nothing}, default::Bool, key::String)
    value === nothing && return default
    # an empty value means "unset", as it does for the integer parameters
    isempty(value) && return default
    lowered = lowercase(value)
    lowered in ("1", "on", "true", "yes") && return true
    lowered in ("0", "off", "false", "no") && return false
    return ConnectionParameterError(key, :invalid_value, "invalid value \"$(escape_string(value))\" for connection parameter \"$key\"; expected a boolean (on/off, true/false, yes/no, 1/0)")
end

# Ignored keywords that change security or connection-selection behavior when
# set: silently dropping "channel_binding=require" or a CRL file would leave
# the caller believing a protection is in place. The values listed are the
# no-op defaults for each keyword; any other value is rejected.
const SECURITY_SENSITIVE_IGNORED = Dict(
    "channel_binding" => ("", "prefer", "disable"),
    "target_session_attrs" => ("", "any"),
    "gsslib" => ("", "gssapi"),
    "sslnegotiation" => ("", "postgres"),
    "sslcompression" => ("", "0"),
    "sslcrl" => ("",),
    "sslcrldir" => ("",),
    "sslpassword" => ("",),
    "requiressl" => ("", "0"),
    "requirepeer" => ("",),
    "hostaddr" => ("",),
    "client_encoding" => ("", "UTF8", "UTF-8", "utf8", "utf-8"),
    "passfile" => ("",),
    "service" => ("",),
    "load_balance_hosts" => ("", "disable"),
    "replication" => ("", "0", "false", "off"),
)

function check_ignored_param(key::String, value::String)
    inert = get(SECURITY_SENSITIVE_IGNORED, key, nothing)
    inert === nothing && return
    value in inert && return
    # never echo the value: for sslpassword it is the client key passphrase
    return ConnectionParameterError(key, :unsupported_ignored, "connection parameter \"$key\" is set to a value Postgres.jl does not support and cannot safely ignore")
end

# An unrecognized key is almost always a typo, and silently dropping it is
# dangerous: "ssl_mode=verify-full" would leave sslmode unset and fall back to
# an unverified connection while the caller believes otherwise. libpq errors
# on unknown keywords for the same reason.
function check_known_param(key::String)
    (key in KNOWN_PARAMS || key in IGNORED_PARAMS) ||
        return ConnectionParameterError(nothing, :unknown_key, "unrecognized connection parameter; recognized parameters are $(join(sort!(collect(KNOWN_PARAMS)), ", "))")
    return nothing
end

function check_known_params(values::Dict{String, String})
    for (key, value) in values
        err = check_known_param(key)
        err === nothing || return err
        if key in IGNORED_PARAMS
            err = check_ignored_param(key, value)
            err === nothing || return err
        end
    end
    return nothing
end

function params_from_values(values::Dict{String, String})
    err = check_known_params(values)
    err === nothing || return err
    merged = connection_defaults()
    merge!(merged, values)
    apply_env_defaults!(merged)
    user = get(merged, "user", "")
    dbname = get(merged, "dbname", user)
    # parsed in the order parse_dsn has always reported them, so both report
    # the same error when several values are invalid
    port = parse_optional_int(get(merged, "port", nothing), "port")
    port isa ConnectionParameterError && return port
    connect_timeout = parse_optional_int(get(merged, "connect_timeout", nothing), "connect_timeout")
    connect_timeout isa ConnectionParameterError && return connect_timeout
    gssdelegation = parse_bool_param(get(merged, "gssdelegation", nothing), false, "gssdelegation")
    gssdelegation isa ConnectionParameterError && return gssdelegation
    statement_timeout = parse_optional_int(get(merged, "statement_timeout", nothing), "statement_timeout")
    statement_timeout isa ConnectionParameterError && return statement_timeout
    statement_cache_maxsize = parse_optional_int(get(merged, "statement_cache_maxsize", nothing), "statement_cache_maxsize")
    statement_cache_maxsize isa ConnectionParameterError && return statement_cache_maxsize
    debug = parse_bool_param(get(merged, "debug", nothing), false, "debug")
    debug isa ConnectionParameterError && return debug
    reconnect = parse_bool_param(get(merged, "reconnect", nothing), false, "reconnect")
    reconnect isa ConnectionParameterError && return reconnect
    numeric_overflow = get(merged, "numeric_overflow", "warn")
    numeric_overflow in ("warn", "error") ||
        return ConnectionParameterError("numeric_overflow", :invalid_value, "numeric_overflow must be :warn or :error")
    return ConnectionParams(
        ;
        host=get(merged, "host", "localhost"),
        # empty values (an unset PGPORT expanded into the environment) fall
        # back to the default rather than failing to parse
        port=something(port, 5432),
        user=user,
        password=get(merged, "password", nothing),
        dbname=dbname,
        application_name=get(merged, "application_name", nothing),
        options=get(merged, "options", nothing),
        connect_timeout=connect_timeout,
        # deliberately NOT empty-tolerant, matching libpq: an unexpanded
        # ${PGSSLMODE} that was meant to be verify-full must fail loudly
        # rather than fall back to the unauthenticated default
        sslmode=haskey(merged, "sslmode") ? lowercase(merged["sslmode"]) : nothing,
        sslrootcert=get(merged, "sslrootcert", nothing),
        sslcert=get(merged, "sslcert", nothing),
        sslkey=get(merged, "sslkey", nothing),
        sslcapath=get(merged, "sslcapath", nothing),
        sslservername=get(merged, "sslservername", nothing),
        # same rule as sslmode: an unexpanded ${PGGSSENCMODE} must fail loudly
        gssencmode=haskey(merged, "gssencmode") ? lowercase(merged["gssencmode"]) : nothing,
        krbsrvname=get(merged, "krbsrvname", nothing),
        gssdelegation=gssdelegation,
        statement_timeout=statement_timeout,
        statement_cache_maxsize=something(statement_cache_maxsize, 100),
        debug=debug,
        numeric_overflow=Symbol(numeric_overflow),
        reconnect=reconnect,
    )
end

function parse_keyword_dsn(dsn::String)
    values = Dict{String, String}()
    i = firstindex(dsn)
    while i <= lastindex(dsn)
        while i <= lastindex(dsn) && (isspace(dsn[i]) || dsn[i] == ';')
            i = nextind(dsn, i)
        end
        i > lastindex(dsn) && break

        key_start = i
        while i <= lastindex(dsn) && dsn[i] != '=' &&
              !isspace(dsn[i]) && dsn[i] != ';'
            i = nextind(dsn, i)
        end
        key_end = prevind(dsn, i)
        key = key_end < key_start ? "" : lowercase(String(dsn[key_start:key_end]))
        isempty(key) && return ConnectionParameterError(nothing, :malformed, "empty connection parameter name")
        # A malformed DSN can put password text in the apparent key.
        err = check_known_param(key)
        err === nothing || return err
        while i <= lastindex(dsn) && isspace(dsn[i])
            i = nextind(dsn, i)
        end
        (i <= lastindex(dsn) && dsn[i] == '=') ||
            return ConnectionParameterError(key, :malformed, "connection parameter \"$key\" is missing '='")
        i = nextind(dsn, i)
        while i <= lastindex(dsn) && isspace(dsn[i])
            i = nextind(dsn, i)
        end

        buf = IOBuffer()
        if i <= lastindex(dsn) && dsn[i] == '\''
            i = nextind(dsn, i)
            closed_quote = false
            while i <= lastindex(dsn)
                c = dsn[i]
                if c == '\\'
                    i = nextind(dsn, i)
                    i <= lastindex(dsn) ||
                        return ConnectionParameterError(key, :malformed, "dangling escape in value for connection parameter \"$key\"")
                    write(buf, dsn[i])
                    i = nextind(dsn, i)
                elseif c == '\''
                    i = nextind(dsn, i)
                    closed_quote = true
                    break
                else
                    write(buf, c)
                    i = nextind(dsn, i)
                end
            end
            closed_quote ||
                return ConnectionParameterError(key, :malformed, "unterminated quoted value for connection parameter \"$key\"")
            if i <= lastindex(dsn) && !isspace(dsn[i]) && dsn[i] != ';'
                return ConnectionParameterError(key, :malformed, "unexpected text after quoted value for connection parameter \"$key\"")
            end
        else
            while i <= lastindex(dsn) && !isspace(dsn[i]) && dsn[i] != ';'
                c = dsn[i]
                if c == '\\'
                    i = nextind(dsn, i)
                    i <= lastindex(dsn) ||
                        return ConnectionParameterError(key, :malformed, "dangling escape in value for connection parameter \"$key\"")
                    write(buf, dsn[i])
                    i = nextind(dsn, i)
                else
                    write(buf, c)
                    i = nextind(dsn, i)
                end
            end
        end
        values[key] = String(take!(buf))
    end
    return values
end

"""
    Postgres.parse_dsn(dsn) -> ConnectionParams

Parse a libpq-style keyword string (`"host=127.0.0.1 user=postgres"`) or a
PostgreSQL URI (`"postgresql://user:pass@host:5432/dbname"`) into
`ConnectionParams`. Unset options fall back
to the `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGAPPNAME`,
`PGCONNECT_TIMEOUT`, `PGSSL*`, `PGGSSENCMODE`, `PGKRBSRVNAME`, and
`PGGSSDELEGATION` environment variables, then to defaults.

Invalid URI syntax is reported as `ArgumentError` without retaining the
underlying parser's input-bearing exception. To find out which parameter is
invalid without parsing the message, use `Postgres.validate_dsn`.
"""
parse_dsn(dsn::String) = throw_parameter_error(try_parse_dsn(dsn))

"""
    Postgres.validate_dsn(dsn) -> Union{Nothing, Postgres.ConnectionParameterError}

Return `nothing` if `Postgres.parse_dsn(dsn)` would succeed,
otherwise a `Postgres.ConnectionParameterError` describing why it would
not. Environment defaults are applied as `parse_dsn` applies them, so an
invalid `PGPORT` is reported too. Where `parse_dsn` throws an `ArgumentError`,
this returns the error instead, with the same message:

    err = Postgres.validate_dsn("host=localhost port=abc")
    err.key     # "port"
    err.reason  # :invalid_value
"""
function validate_dsn(dsn::Union{String, Nothing})
    result = try_parse_dsn(dsn)
    return result isa ConnectionParameterError ? result : nothing
end

function throw_parameter_error(result)
    result isa ConnectionParameterError && throw(ArgumentError(result.msg))
    return result
end

function try_parse_dsn(dsn::String)
    lowered = lowercase(dsn)
    if startswith(lowered, "postgres://") || startswith(lowered, "postgresql://")
        values = parse_uri(dsn)
    else
        values = parse_keyword_dsn(dsn)
    end
    values isa ConnectionParameterError && return values
    return params_from_values(values)
end

try_parse_dsn(::Nothing) = params_from_values(Dict{String, String}())

function parse_uri(uri::String)
    values = try
        parse_uri_values(uri)
    catch err
        (err isa URIs.ParseError || err isa ArgumentError || err isa EOFError) || rethrow()
        nothing
    end
    # Report outside the catch so the exception chain cannot expose credentials.
    values === nothing && return ConnectionParameterError(nothing, :malformed, "invalid PostgreSQL URI; check syntax and percent-encoding")
    return values
end

function parse_uri_values(uri::String)
    parsed = URIs.URI(uri)
    scheme = lowercase(String(parsed.scheme))
    (scheme == "postgres" || scheme == "postgresql") || throw(ArgumentError("invalid PostgreSQL URI scheme: $scheme"))
    values = Dict{String, String}()
    userinfo = String(parsed.userinfo)
    if !isempty(userinfo)
        if occursin(':', userinfo)
            usr, pwd = split(userinfo, ':'; limit=2)
            values["user"] = URIs.unescapeuri(usr)
            values["password"] = URIs.unescapeuri(pwd)
        else
            values["user"] = URIs.unescapeuri(userinfo)
        end
    end

    host = String(parsed.host)
    !isempty(host) && (values["host"] = URIs.unescapeuri(host))
    port = String(parsed.port)
    !isempty(port) && (values["port"] = port)

    path = String(parsed.path)
    if startswith(path, "/") && length(path) > 1
        values["dbname"] = URIs.unescapeuri(path[nextind(path, firstindex(path)):end])
    end

    query = String(parsed.query)
    if !isempty(query)
        params = URIs.queryparams(query)
        for (key, value) in params
            values[key] = value
        end
    end
    return values
end

parse_dsn(dsn::Nothing) = throw_parameter_error(try_parse_dsn(dsn))

export ConnectionParams, parse_dsn, validate_dsn, ConnectionParameterError

end
