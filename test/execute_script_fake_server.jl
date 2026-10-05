# execute_script against a scripted server: simple-query responses a live
# PostgreSQL produces only for particular statements (COPY in either direction,
# CopyBoth) or that need a precise interleaving (notices and rows between
# command tags, an error after earlier statements completed). Reuses the
# fake-server helpers from gssapi.jl and isvalid_fake_server.jl.

struct ScriptLogStyle <: Postgres.API.AbstractPostgresStyle
    events::Vector{Any}
end
Postgres.API.query_logging_enabled(::ScriptLogStyle) = true
Postgres.API.query_logger(s::ScriptLogStyle, event::Symbol, info::NamedTuple) = (push!(s.events, (event, info)); nothing)

tag_msg(tag) = pgmsg('C', vcat(Vector{UInt8}(tag), 0x00))
ready_msg(status::Char) = pgmsg('Z', [UInt8(status)])
# CopyInResponse / CopyOutResponse / CopyBothResponse: text format, no columns
copy_response(code::Char) = pgmsg(code, UInt8[0x00, 0x00, 0x00])

# read the client's simple-query message and check its text
function read_query(sock, sql)
    code, body = read_message(sock)
    code == 'Q' || error("fake server: expected Query, got '$code'")
    String(body[1:end-1]) == sql || error("fake server: unexpected query text")
    return
end

function test_execute_script_fake_server()
@testset "execute_script against a scripted server" begin
    @testset "returns each command tag; rows skipped, async messages dispatched" begin
        sql = "CREATE TABLE t (a int); COMMENT ON TABLE t IS 'one; two'; SELECT 1"
        style = RecordingStyle()
        with_fake_server(serve_idle(sock -> begin
            read_query(sock, sql)
            send(sock, vcat(tag_msg("CREATE TABLE"), notice_msg("NOTICE", "00000", "script notice"),
                            param_status("TimeZone", "UTC"), notification_msg(7, "chan", "payload"),
                            tag_msg("COMMENT"), pgmsg('T', UInt8[0x00, 0x00]), pgmsg('D', UInt8[0x00, 0x00]),
                            tag_msg("SELECT 1"), ready_msg('I')))
            drain(sock)
        end)) do port, accepted
            conn = fake_connection(port, style)
            @test Postgres.execute_script(conn, sql) == ["CREATE TABLE", "COMMENT", "SELECT 1"]
            @test length(style.notices) == 1
            @test any(==("script notice"), values(style.notices[1]))
            @test Postgres.get_server_parameter(conn, "TimeZone") == "UTC"
            @test length(style.notifications) == 1
            @test style.notifications[1].channel == "chan"
            @test isopen(conn)
            @test !conn.server_in_transaction
            close(conn)
        end
    end

    @testset "an empty script returns no tags" begin
        with_fake_server(serve_idle(sock -> begin
            read_query(sock, "")
            send(sock, vcat(pgmsg('I', UInt8[]), ready_msg('I')))
            drain(sock)
        end)) do port, accepted
            conn = fake_connection(port, Postgres.PostgresStyle())
            @test Postgres.execute_script(conn, "") == String[]
            close(conn)
        end
    end

    @testset "a server error is thrown after draining; transaction status tracked" begin
        style = ScriptLogStyle(Any[])
        with_fake_server(serve_idle(sock -> begin
            read_query(sock, "BEGIN; SELECT 1; SELECT * FROM missing")
            send(sock, vcat(tag_msg("BEGIN"), tag_msg("SELECT 1"),
                            error_response("ERROR", "42P01", "relation \"missing\" does not exist"), ready_msg('E')))
            read_query(sock, "ROLLBACK")
            send(sock, vcat(tag_msg("ROLLBACK"), ready_msg('I')))
            drain(sock)
        end)) do port, accepted
            conn = fake_connection(port, style)
            err = connect_err(() -> Postgres.execute_script(conn, "BEGIN; SELECT 1; SELECT * FROM missing"))
            @test err isa Postgres.API.Error
            @test err.code == "42P01"
            @test isopen(conn)
            @test conn.server_in_transaction
            @test Postgres.execute_script(conn, "ROLLBACK") == ["ROLLBACK"]
            @test !conn.server_in_transaction
            @test [(event, info.success) for (event, info) in style.events] ==
                  [(:execute_script, false), (:execute_script, true)]
            @test style.events[1][2].error === err
            @test style.events[2][2].sql == "ROLLBACK"
            @test accepted[] == 1
            close(conn)
        end
    end

    @testset "COPY FROM STDIN is aborted with CopyFail; connection stays usable" begin
        with_fake_server(serve_idle(sock -> begin
            read_query(sock, "SELECT 1; COPY t FROM STDIN")
            send(sock, vcat(tag_msg("SELECT 1"), copy_response('G')))
            code, _ = read_message(sock)
            code == 'f' || error("fake server: expected CopyFail, got '$code'")
            send(sock, vcat(error_response("ERROR", "57014", "COPY from stdin failed"), ready_msg('I')))
            read_query(sock, "SELECT 1")
            send(sock, vcat(tag_msg("SELECT 1"), ready_msg('I')))
            drain(sock)
        end)) do port, accepted
            conn = fake_connection(port, Postgres.PostgresStyle())
            err = connect_err(() -> Postgres.execute_script(conn, "SELECT 1; COPY t FROM STDIN"))
            @test err isa Postgres.PostgresInterfaceError
            @test occursin("copy_from", errtext(err))
            @test isopen(conn)
            @test Postgres.execute_script(conn, "SELECT 1") == ["SELECT 1"]
            close(conn)
        end
    end

    @testset "COPY TO STDOUT is drained and rejected; a server error wins" begin
        with_fake_server(serve_idle(sock -> begin
            read_query(sock, "COPY t TO STDOUT; SELECT 1")
            send(sock, vcat(copy_response('H'), pgmsg('d', Vector{UInt8}("1\n")), pgmsg('c', UInt8[]),
                            tag_msg("COPY 1"), tag_msg("SELECT 1"), ready_msg('I')))
            read_query(sock, "COPY (SELECT 1/0) TO STDOUT")
            send(sock, vcat(copy_response('H'),
                            error_response("ERROR", "22012", "division by zero"), ready_msg('I')))
            drain(sock)
        end)) do port, accepted
            conn = fake_connection(port, Postgres.PostgresStyle())
            err = connect_err(() -> Postgres.execute_script(conn, "COPY t TO STDOUT; SELECT 1"))
            @test err isa Postgres.PostgresInterfaceError
            @test occursin("copy_to", errtext(err))
            @test isopen(conn)
            err = connect_err(() -> Postgres.execute_script(conn, "COPY (SELECT 1/0) TO STDOUT"))
            @test err isa Postgres.API.Error
            @test err.code == "22012"
            @test isopen(conn)
            close(conn)
        end
    end

    @testset "CopyBothResponse closes the connection" begin
        with_fake_server(serve_idle(sock -> begin
            read_query(sock, "START_REPLICATION")
            send(sock, copy_response('W'))
            drain(sock)
        end)) do port, accepted
            conn = fake_connection(port, Postgres.PostgresStyle())
            err = connect_err(() -> Postgres.execute_script(conn, "START_REPLICATION"))
            @test err isa Postgres.API.Error
            @test occursin("unexpected message type 'W'", errtext(err))
            @test !isopen(conn)
        end
    end
end
end
