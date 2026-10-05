using Dates
using DBInterface
using Postgres
using StructUtils
using UUIDs

@enum TrimStatus trim_active trim_paused

struct TrimId
    profile_id::Int32
end

StructUtils.@tags struct TrimProfile
    profileId::Int32 &(postgres=(name=:profile_id,),)
    displayName::String &(postgres=(name=:display_name,),)
    nickname::Union{Nothing, String}
    createdAt::DateTime &(postgres=(name=:created_at,),)
    deletedAt::Union{Nothing, DateTime} &(postgres=(name=:deleted_at,),)
    birthday::Union{Nothing, Date}
    active::Bool
    score::Union{Missing, Int32}
    balance::Float64
    status::TrimStatus
    uid::UUID
    flags::Vector{Int32}
    tags::Vector{String}
    settings::String
end

struct TrimTotals
    total::Int64
    rows::Union{Nothing, Int64}
end

const TRIM_PROFILE_SELECT = """
    SELECT profile_id, display_name, nickname, created_at, deleted_at, birthday, active,
           score, balance, status, uid, flags, tags, settings
    FROM trim_compile_profiles
    """

function _postgres_trim_connect()
    port = Base.parse(Int, get(ENV, "POSTGRES_TRIM_PORT", "5432"))
    return DBInterface.connect(
        Postgres.Connection,
        get(ENV, "POSTGRES_TRIM_HOST", "127.0.0.1"),
        get(ENV, "POSTGRES_TRIM_USER", "postgres"),
        get(ENV, "POSTGRES_TRIM_PASSWORD", "postgres");
        dbname=get(ENV, "POSTGRES_TRIM_DBNAME", "postgres"),
        port=port,
        sslmode="disable",
        connect_timeout=5,
        application_name="postgres_trim",
        options="-c search_path=public",
        statement_timeout=30_000,
        statement_cache_maxsize=4,
    )
end

function _check(cond::Bool, msg::String)::Nothing
    cond || error(msg)
    return nothing
end

function _check_profile(p::TrimProfile, id::Int32, name::String)::Nothing
    _check(p.profileId == id, "unexpected profile id")
    _check(p.displayName == name, "unexpected profile name")
    _check(p.active, "expected active profile")
    _check(!isempty(p.flags) && !isempty(p.tags), "expected non-empty arrays")
    _check(startswith(p.settings, "{"), "expected jsonb text in a String field")
    return nothing
end

function run_postgres_trim_queries()::Nothing
    conn = _postgres_trim_connect()
    try
        DBInterface.execute(conn, "DROP TYPE IF EXISTS trim_status")
        DBInterface.execute(conn, "CREATE TYPE trim_status AS ENUM ('trim_active', 'trim_paused')")
        DBInterface.execute(conn, """
            CREATE TEMP TABLE trim_compile_profiles (
                profile_id integer PRIMARY KEY,
                display_name text NOT NULL,
                nickname text,
                created_at timestamp NOT NULL,
                deleted_at timestamptz,
                birthday date,
                active boolean NOT NULL,
                score integer,
                balance numeric(10, 2) NOT NULL,
                status trim_status NOT NULL,
                uid uuid NOT NULL,
                flags integer[] NOT NULL,
                tags text[] NOT NULL,
                settings jsonb NOT NULL
            )
            """)
        insert_sql = raw"""
            INSERT INTO trim_compile_profiles VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9::numeric, $10::trim_status, $11,
                $12::integer[], $13::text[], $14::jsonb
            )
            RETURNING profile_id
            """
        first_id = DBInterface.execute(conn, insert_sql, (
                Int32(1), "Ada", "ada", DateTime(2024, 1, 2, 3, 4, 5), missing, Date(1815, 12, 10), true,
                Int32(99), "12.50", "trim_active", UUID("12345678-1234-5678-1234-567812345678"),
                "{1,2,3}", "{math,poetry}", "{\"theme\": \"dark\"}",
            ), TrimId)
        _check(first_id.profile_id == 1, "unexpected inserted id")
        DBInterface.transaction(conn) do
            DBInterface.execute(conn, insert_sql, (
                Int32(2), "Grace", missing, DateTime(2024, 1, 3, 4, 5, 6), DateTime(2024, 2, 1), missing, true,
                missing, "0.00", "trim_paused", UUID("87654321-4321-8765-4321-876543218765"),
                "{4,5}", "{navy}", "{}",
            ))
        end

        stmt = DBInterface.prepare(conn, TRIM_PROFILE_SELECT * raw"WHERE profile_id = $1")
        try
            profile = DBInterface.execute(stmt, (Int32(1),), TrimProfile)
            _check_profile(profile, Int32(1), "Ada")
            _check(profile.nickname == "ada" && profile.deletedAt === nothing, "unexpected nullable fields")
            _check(profile.balance == 12.5 && profile.status == trim_active, "unexpected numeric or enum field")
        finally
            DBInterface.close!(stmt)
        end

        profiles = DBInterface.execute(conn, TRIM_PROFILE_SELECT * "ORDER BY profile_id", (), Vector{TrimProfile})
        _check(length(profiles) == 2, "expected two profiles")
        _check_profile(profiles[2], Int32(2), "Grace")
        _check(profiles[2].score === missing && profiles[2].deletedAt == DateTime(2024, 2, 1), "unexpected nullable fields")

        totals = DBInterface.execute(conn,
            "SELECT sum(balance)::numeric(10, 2) AS total, count(*) AS rows FROM trim_compile_profiles WHERE balance = 0",
            (), TrimTotals)
        _check(totals.total == 0 && totals.rows == 1, "unexpected aggregate fields")

        result = DBInterface.execute(conn, "UPDATE trim_compile_profiles SET score = coalesce(score, 0) + 1")
        _check(Postgres.rows_affected(result) == 2, "unexpected rows affected")
        _check(occursin("UPDATE", Postgres.command_tag(result)), "unexpected command tag")
    finally
        DBInterface.close!(conn)
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    run_postgres_trim_queries()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
