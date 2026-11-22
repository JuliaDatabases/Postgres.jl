module ArrayParsing

using Parsers, Dates, UUIDs
import Durations, DataDecimals
import ..parse_decimal
import ..pg_parse_timestamp
import ..pg_parse_date, ..pg_parse_date_any, ..pg_parse_time_any, ..pg_parse_datetime, ..pg_parse_char, ..pg_parse_integer

const BRACKET_OPEN = UInt8('[')
const BRACKET_CLOSE = UInt8(']')
const BRACE_OPEN = UInt8('{')
const BRACE_CLOSE = UInt8('}')
const COMMA = UInt8(',')
const QUOTE = UInt8('"')
const BACKSLASH = UInt8('\\')
const NULL_STR = "NULL"
const SPACE = UInt8(' ')
const TAB = UInt8('\t')
const NEWLINE = UInt8('\n')
const CARRIAGE_RETURN = UInt8('\r')

is_ws(c::UInt8) = c == SPACE || c == TAB || c == NEWLINE || c == CARRIAGE_RETURN

function skip_ws(code::Base.CodeUnits{UInt8, String}, pos::Ref{Int})
    while pos[] <= length(code) && is_ws(code[pos[]])
        pos[] += 1
    end
    return
end

function parse_quoted(code::Base.CodeUnits{UInt8, String}, pos::Ref{Int})
    pos[] += 1
    buf = UInt8[]
    while pos[] <= length(code)
        c = code[pos[]]
        if c == BACKSLASH
            pos[] += 1
            pos[] <= length(code) || break
            push!(buf, code[pos[]])
            pos[] += 1
        elseif c == QUOTE
            pos[] += 1
            return String(buf)
        else
            push!(buf, c)
            pos[] += 1
        end
    end
    return String(buf)
end

function parse_unquoted(code::Base.CodeUnits{UInt8, String}, pos::Ref{Int})
    buf = UInt8[]
    while pos[] <= length(code)
        c = code[pos[]]
        # ']' is NOT a terminator: postgres only quotes elements containing
        # '"', '\\', '{', '}', ',' or whitespace, so an unquoted ']' (file
        # paths, "x[1]", embedded JSON) is ordinary element data. Treating it
        # as a terminator silently truncated the element and dropped every
        # element after it.
        if c == COMMA || c == BRACE_CLOSE
            break
        elseif c == BACKSLASH
            pos[] += 1
            pos[] <= length(code) || break
            push!(buf, code[pos[]])
            pos[] += 1
        else
            push!(buf, c)
            pos[] += 1
        end
    end
    # The server quotes any element that contains ASCII whitespace, so an
    # unquoted element runs to the delimiter. Unicode spaces such as U+00A0
    # are never quoted and belong to the element: do not strip.
    return String(buf)
end

function parse_bool_token(token::String)
    lowered = lowercase(token)
    lowered == "t" && return true
    lowered == "true" && return true
    lowered == "1" && return true
    lowered == "f" && return false
    lowered == "false" && return false
    lowered == "0" && return false
    throw(ArgumentError("invalid boolean token: $token"))
end

function parse_scalar(token::String, inner_type::Type{T}, quoted::Bool) where {T}
    !quoted && token == NULL_STR && return missing
    inner_type === String && return token
    inner_type === Bool && return parse_bool_token(token)
    inner_type === Int16 && return pg_parse_integer(Int16, token)
    inner_type === Int32 && return pg_parse_integer(Int32, token)
    inner_type === Int64 && return pg_parse_integer(Int64, token)
    inner_type === Float32 && return Parsers.parse(Float32, token)
    inner_type === Float64 && return Parsers.parse(Float64, token)
    inner_type === Date && return pg_parse_date_any(token)
    inner_type === Time && return pg_parse_time_any(token)
    inner_type <: Durations.Timestamp && return pg_parse_timestamp(token, inner_type)
    inner_type === DateTime && return pg_parse_datetime(token)
    inner_type === UUID && return UUID(token)
    inner_type <: DataDecimals.AbstractDecimal && return parse_decimal(inner_type, token)
    inner_type === Char && return pg_parse_char(token)
    return token
end

function coerce_array(values::Vector{Any}, inner_type::Type{T}) where {T}
    isempty(values) && return inner_type[]
    has_nested = false
    has_missing = false
    for value in values
        value isa AbstractVector && (has_nested = true; break)
        value === missing && (has_missing = true)
    end
    # nested arrays stay Vector{Any}: narrowing to the runtime element type
    # would need a runtime-typed Vector construction, which `juliac --trim`
    # cannot resolve. The values themselves are fully parsed either way.
    has_nested && return values
    if has_missing
        dest = Union{inner_type, Missing}[]
        sizehint!(dest, length(values))
        for value in values
            if value === missing
                push!(dest, value)
            elseif value isa inner_type
                push!(dest, value)
            else
                return values
            end
        end
        return dest
    end
    dest = inner_type[]
    sizehint!(dest, length(values))
    for value in values
        value isa inner_type || return values
        push!(dest, value)
    end
    return dest
end

function parse_array_value(code::Base.CodeUnits{UInt8, String}, pos::Ref{Int}, inner_type::Type{T}) where {T}
    c = code[pos[]]
    if c == BRACE_OPEN
        return parse_array_inner(code, pos, inner_type)
    elseif c == QUOTE
        token = parse_quoted(code, pos)
        return parse_scalar(token, inner_type, true)
    else
        token = parse_unquoted(code, pos)
        return parse_scalar(token, inner_type, false)
    end
end

function parse_array_inner(code::Base.CodeUnits{UInt8, String}, pos::Ref{Int}, inner_type::Type{T}) where {T}
    values = Any[]
    pos[] += 1
    while pos[] <= length(code)
        skip_ws(code, pos)
        pos[] > length(code) && break
        c = code[pos[]]
        if c == BRACE_CLOSE
            pos[] += 1
            break
        end
        value = parse_array_value(code, pos, inner_type)
        push!(values, value)
        skip_ws(code, pos)
        if pos[] <= length(code) && code[pos[]] == COMMA
            pos[] += 1
        end
    end
    return coerce_array(values, inner_type)
end

# Whether the literal is one `parse_flat_array` gives up on, told without
# reading any element: a nested array (the server writes `{{`), a backslash
# escape, or the bytes `NULL`. Memchr scans keep this cheap. A quoted "NULL" or
# a word containing it also counts; the general parser reads those the same way.
function needs_general_parser(code::Base.CodeUnits{UInt8, String}, open::Int)
    open < length(code) && code[open + 1] == BRACE_OPEN && return true
    findfirst(==(BACKSLASH), code) !== nothing && return true
    i = findfirst(==(UInt8('N')), code)
    while i !== nothing
        i + 3 <= length(code) && code[i + 1] == UInt8('U') && code[i + 2] == UInt8('L') && code[i + 3] == UInt8('L') && return true
        i = findnext(==(UInt8('N')), code, i + 1)
    end
    return false
end

# The common case, a one-dimensional array without NULLs or escapes, read
# straight into a `Vector{T}`. `parse_array_inner` copies each token through a
# growable buffer and boxes each value into a `Vector{Any}` first. Elements are
# split and parsed exactly as there. Returns `nothing` when
# `needs_general_parser` says so, so such a literal is parsed once, or at a
# later nested array or a value that is not a `T`; the caller then parses the
# whole literal with `parse_array_inner`.
function parse_flat_array(str::String, open::Int, inner_type::Type{T}) where {T}
    code = codeunits(str)
    needs_general_parser(code, open) && return nothing
    n = length(code)
    dest = T[]
    i = open + 1
    while i <= n
        while i <= n && is_ws(code[i])
            i += 1
        end
        i > n && break
        c = code[i]
        c == BRACE_CLOSE && break
        c == BRACE_OPEN && return nothing
        quoted = c == QUOTE
        quoted && (i += 1)
        j = i
        while j <= n
            b = code[j]
            (quoted ? b == QUOTE : (b == COMMA || b == BRACE_CLOSE)) && break
            j += 1
        end
        token = GC.@preserve str unsafe_string(pointer(str, i), j - i)
        # a quoted element ends past its closing quote
        i = quoted && j <= n ? j + 1 : j
        value = parse_scalar(token, inner_type, quoted)
        value isa T || return nothing
        push!(dest, value)
        while i <= n && is_ws(code[i])
            i += 1
        end
        i <= n && code[i] == COMMA && (i += 1)
    end
    return dest
end

const EQUALS = UInt8('=')

# PostgreSQL prefixes an array literal with explicit dimensions whenever a
# lower bound isn't 1: "[0:2]={a,b,c}", "[1:2][1:2]={{1,2},{3,4}}". Skip the
# prefix so the rest parses as an ordinary array literal — otherwise the '['
# is taken for an array-open bracket and the real elements are lost.
function skip_dimension_prefix!(code::Base.CodeUnits{UInt8, String}, pos::Ref{Int})
    start = pos[]
    n = length(code)
    while pos[] <= n && code[pos[]] == BRACKET_OPEN
        close_idx = pos[]
        while close_idx <= n && code[close_idx] != BRACKET_CLOSE
            close_idx += 1
        end
        if close_idx > n
            pos[] = start
            return
        end
        pos[] = close_idx + 1
    end
    if pos[] > start && pos[] <= n && code[pos[]] == EQUALS
        pos[] += 1
        return
    end
    pos[] = start
    return
end

function parse_array(str::String, inner_type::Type{T}) where {T}
    code = codeunits(str)
    pos = Ref{Int}(1)
    skip_ws(code, pos)
    if pos[] > length(code)
        return inner_type[]
    end
    skip_dimension_prefix!(code, pos)
    skip_ws(code, pos)
    if pos[] > length(code)
        return inner_type[]
    end
    c = code[pos[]]
    if c == BRACE_OPEN
        flat = parse_flat_array(str, pos[], inner_type)
        flat === nothing || return flat
        return parse_array_inner(code, pos, inner_type)
    end
    value = parse_scalar(str, inner_type, true)
    return coerce_array(Any[value], inner_type)
end

export parse_array

end
