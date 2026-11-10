# connect_timeout against scripted servers that stall at each stage of a
# connection attempt. Reuses the fake-server helpers from gssapi.jl,
# isvalid_fake_server.jl, and execute_fake_server.jl.

timeout_connection(port; kw...) = Postgres.Connection(; host="127.0.0.1", port=port, user="u", dbname="db",
                                                      gssencmode="disable", connect_timeout=1, kw...)

function expect_connect_timeout(f)
    started = time()
    err = connect_err(f)
    @test err isa Postgres.Error
    @test occursin("timeout expired", errtext(err))
    @test time() - started < 5
    return
end

# answers one statement's Parse/Describe/Bind/Execute/Sync with no data
function serve_statement(sock)
    read_unnamed_segment(sock)
    send(sock, no_data_replies("DO"))
    return
end

function test_connect_timeout_fake_server()
@testset "connect_timeout bounds the whole connection attempt" begin
    @testset "server silent after accepting (sslmode=$sslmode)" for sslmode in ("disable", "prefer")
        with_fake_server((sock, n) -> drain(sock)) do port, accepted
            expect_connect_timeout(() -> timeout_connection(port; sslmode=sslmode))
        end
    end

    @testset "TLS handshake stalls" begin
        with_fake_server((sock, n) -> begin
            read_request(sock)
            send(sock, [UInt8('S')])
            drain(sock)
        end) do port, accepted
            expect_connect_timeout(() -> timeout_connection(port; sslmode="require"))
        end
    end

    @testset "one deadline for all stages, not one per stage" begin
        # each stage answers within connect_timeout, but together they take longer
        with_fake_server((sock, n) -> begin
            read_request(sock)
            sleep(0.6)
            send(sock, [UInt8('N')])
            read_startup(sock)
            sleep(0.6)
            ready!(sock)
            drain(sock)
        end) do port, accepted
            expect_connect_timeout(() -> timeout_connection(port; sslmode="prefer"))
        end
    end

    @testset "a statement after connect_timeout has passed succeeds" begin
        with_fake_server(serve_idle(sock -> (serve_statement(sock); drain(sock)))) do port, accepted
            conn = timeout_connection(port; sslmode="disable")
            sleep(1.5)
            @test Postgres.command_tag(DBInterface.execute(conn, "DO 1")) == "DO"
            @test isopen(conn)
            close(conn)
        end
    end

    @testset "... also after a reconnect" begin
        handler = function (sock, n)
            serve_idle(sock -> begin
                if n == 1
                    read_unnamed_segment(sock)
                    close(sock)
                else
                    serve_statement(sock)
                    serve_statement(sock)
                    drain(sock)
                end
            end)(sock, n)
        end
        with_fake_server(handler) do port, accepted
            conn = timeout_connection(port; sslmode="disable", reconnect=true)
            @test connect_err(() -> DBInterface.execute(conn, "DO 1")) isa EOFError
            @test_logs (:warn, r"reconnected") DBInterface.execute(conn, "DO 1")
            @test accepted[] == 2
            sleep(1.5)
            @test Postgres.command_tag(DBInterface.execute(conn, "DO 1")) == "DO"
            close(conn)
        end
    end

    @testset "cancel_request gives up when the server stalls" begin
        with_fake_server((sock, n) -> drain(sock)) do port, accepted
            started = time()
            # the SSLRequest is never answered
            @test !Postgres.API.cancel_request("127.0.0.1", port, Int32(1), Int32(1), false, "prefer",
                                               nothing, nothing, nothing, nothing, nothing, 1)
            @test time() - started < 5
        end
    end
end
end
