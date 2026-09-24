# Unnamed execute against a scripted server: the connection failing before the
# replies to Parse/Describe/Bind arrive. A live server does not flush those
# replies until Execute finishes, so a connection lost during a long statement
# fails here. Reuses the fake-server helpers from gssapi.jl and
# isvalid_fake_server.jl.

# read the client's Parse/Describe/Bind/Execute/Sync segment
function read_unnamed_segment(sock)
    types = Char[first(read_message(sock)) for _ in 1:5]
    types == ['P', 'D', 'B', 'E', 'S'] || error("fake server: unexpected segment $types")
    return
end

# the replies to one unnamed statement with no parameters and no result columns
no_data_replies(tag) = vcat(pgmsg('1', UInt8[]), pgmsg('t', UInt8[0x00, 0x00]), pgmsg('n', UInt8[]),
                            pgmsg('2', UInt8[]), pgmsg('C', vcat(Vector{UInt8}(tag), 0x00)), pgmsg('Z', [UInt8('I')]))

execute_connection(port; reconnect=false) = Postgres.Connection(host="127.0.0.1", port=port, user="u", dbname="db",
                                                               sslmode="disable", gssencmode="disable", reconnect=reconnect)

function test_execute_fake_server()
@testset "unnamed execute against a scripted server" begin
    # the replies the server gets out before the connection is lost
    partial_replies = (
        "before ParseComplete" => UInt8[],
        "before ParameterDescription" => pgmsg('1', UInt8[]),
        "before BindComplete" => vcat(pgmsg('1', UInt8[]), pgmsg('t', UInt8[0x00, 0x00]), pgmsg('n', UInt8[])),
    )
    for (label, sent) in partial_replies
        @testset "connection lost $label" begin
            with_fake_server(serve_idle(sock -> begin
                read_unnamed_segment(sock)
                isempty(sent) || send(sock, sent)
                close(sock)
            end)) do port, accepted
                conn = execute_connection(port)
                err = connect_err(() -> DBInterface.execute(conn, "SELECT pg_sleep(\$1)", [60]))
                @test err isa EOFError
                # the stream position is unknown: the socket must not be reused
                @test !isopen(conn)
                err = connect_err(() -> DBInterface.execute(conn, "SELECT 1"))
                @test err isa Postgres.PostgresInterfaceError
                @test occursin("closed or disconnected", errtext(err))
            end
        end
    end

    @testset "connection lost before ParseComplete reconnects on next use" begin
        handler = function (sock, n)
            serve_idle(sock -> begin
                read_unnamed_segment(sock)
                if n == 1
                    close(sock)
                else
                    send(sock, no_data_replies("DO"))
                    drain(sock)
                end
            end)(sock, n)
        end
        with_fake_server(handler) do port, accepted
            conn = execute_connection(port; reconnect=true)
            @test connect_err(() -> DBInterface.execute(conn, "DO \$\$ BEGIN PERFORM pg_sleep(60); END \$\$")) isa EOFError
            @test !isopen(conn)
            result = @test_logs (:warn, r"reconnected") DBInterface.execute(conn, "DO \$\$ BEGIN END \$\$")
            @test Postgres.command_tag(result) == "DO"
            @test accepted[] == 2
            @test isopen(conn)
            close(conn)
        end
    end

    @testset "a server error before ParseComplete keeps the connection" begin
        with_fake_server(serve_idle(sock -> begin
            read_unnamed_segment(sock)
            send(sock, vcat(error_response("ERROR", "42601", "syntax error"), pgmsg('Z', [UInt8('I')])))
            read_unnamed_segment(sock)
            send(sock, no_data_replies("DO"))
            drain(sock)
        end)) do port, accepted
            conn = execute_connection(port)
            err = connect_err(() -> DBInterface.execute(conn, "SELEC 1"))
            @test err isa Postgres.API.Error
            @test err.code == "42601"
            @test isopen(conn)
            @test Postgres.command_tag(DBInterface.execute(conn, "DO \$\$ BEGIN END \$\$")) == "DO"
            @test accepted[] == 1
            close(conn)
        end
    end
end
end
