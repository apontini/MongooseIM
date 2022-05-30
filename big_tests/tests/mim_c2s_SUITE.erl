-module(mim_c2s_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("exml/include/exml.hrl").
-include_lib("exml/include/exml_stream.hrl").

-import(distributed_helper, [mim/0, rpc/4]).
-import(domain_helper, [host_type/0, domain/0]).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [
     {group, basic},
     {group, proxy_protocol},
     {group, incorrect_behaviors},
     {group, security},
     {group, session_replacement}
    ].

groups() ->
    [
     {basic, [parallel],
      [
       log_one,
       log_two,
       do_starttls
      ]},
     {incorrect_behaviors, [parallel],
      [
       close_connection_if_start_stream_duplicated,
       close_connection_if_protocol_violation_after_authentication,
       close_connection_if_protocol_violation_after_binding
      ]},
     {security, [],
      [
       return_proper_stream_error_if_service_is_not_hidden,
       close_connection_if_service_type_is_hidden
      ]},
     {session_replacement, [],
      [
       same_resource_replaces_session,
       clean_close_of_replaced_session,
       replaced_session_cannot_terminate
      ]},
     {proxy_protocol, [parallel],
      [
       cannot_connect_without_proxy_header,
       connect_with_proxy_header
      ]}
    ].

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------
init_per_suite(Config) ->
    escalus:init_per_suite(Config).

end_per_suite(Config) ->
    escalus_fresh:clean(),
    escalus:end_per_suite(Config).

init_per_group(session_replacement, Config) ->
    logger_ct_backend:start(),
    init_per_group(generic, Config);
init_per_group(GroupName, Config) ->
    rpc(mim(), mongoose_listener, start_listener, [m_listener(GroupName)]),
    Config.

end_per_group(session_replacement, Config) ->
    logger_ct_backend:stop(),
    end_per_group(generic, Config);
end_per_group(GroupName, _Config) ->
    rpc(mim(), mongoose_listener, stop_listener, [m_listener(GroupName)]),
    ok.

init_per_testcase(replaced_session_cannot_terminate = CN, Config) ->
    S = escalus_users:get_server(Config, alice_m),
    OptKey = {replaced_wait_timeout, S},
    Config1 = mongoose_helper:backup_and_set_config_option(Config, OptKey, 1),
    escalus:init_per_testcase(CN, Config1);
init_per_testcase(close_connection_if_service_type_is_hidden = CN, Config) ->
    Config1 = mongoose_helper:backup_and_set_config_option(Config, hide_service_name, true),
    escalus:init_per_testcase(CN, Config1);
init_per_testcase(Name, Config) ->
    escalus:init_per_testcase(Name, Config).

end_per_testcase(Name, Config) ->
    mongoose_helper:restore_config(Config),
    escalus:end_per_testcase(Name, Config).

%%--------------------------------------------------------------------
%% tests
%%--------------------------------------------------------------------
log_one(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {alice_m, 1}], fun(EC2S, MC2S) ->
        escalus_client:send(EC2S, escalus_stanza:chat_to(MC2S, <<"Hi!">>)),
        escalus:assert(is_chat_message, [<<"Hi!">>], escalus_client:wait_for_stanza(MC2S)),
        escalus_client:send(MC2S, escalus_stanza:chat_to(EC2S, <<"Hi!">>)),
        escalus:assert(is_chat_message, [<<"Hi!">>], escalus_client:wait_for_stanza(EC2S))
    end).

log_two(Config) ->
    escalus:fresh_story(Config, [{alice_m, 1}, {bob_m, 1}], fun(Alice, Bob) ->
        escalus_client:send(Alice, escalus_stanza:chat_to(Bob, <<"Hi!">>)),
        escalus:assert(is_chat_message, [<<"Hi!">>], escalus_client:wait_for_stanza(Bob)),
        escalus_client:send(Bob, escalus_stanza:chat_to(Alice, <<"Hi!">>)),
        escalus:assert(is_chat_message, [<<"Hi!">>], escalus_client:wait_for_stanza(Alice))
    end).

do_starttls(Config) ->
    escalus:fresh_story(Config, [{secure_joe, 1}, {secure_joe_m, 1}], fun(EC2S, MC2S) ->
        escalus_client:send(EC2S, escalus_stanza:chat_to(MC2S, <<"Hi!">>)),
        escalus:assert(is_chat_message, [<<"Hi!">>], escalus_client:wait_for_stanza(MC2S)),
        escalus_client:send(MC2S, escalus_stanza:chat_to(EC2S, <<"Hi!">>)),
        escalus:assert(is_chat_message, [<<"Hi!">>], escalus_client:wait_for_stanza(EC2S))
    end).

close_connection_if_start_stream_duplicated(Config) ->
    close_connection_if_protocol_violation(Config, [start_stream, stream_features]).

close_connection_if_protocol_violation_after_authentication(Config) ->
    close_connection_if_protocol_violation(Config, [start_stream, stream_features, authenticate]).

close_connection_if_protocol_violation_after_binding(Config) ->
    close_connection_if_protocol_violation(Config, [start_stream, stream_features, authenticate, bind]).

close_connection_if_protocol_violation(Config, Steps) ->
    AliceSpec = escalus_fresh:create_fresh_user(Config, alice_m),
    {ok, Alice, _Features} = escalus_connection:start(AliceSpec, Steps),
    escalus:send(Alice, escalus_stanza:stream_start(domain(), ?NS_JABBER_CLIENT)),
    escalus:assert(is_stream_error, [<<"policy-violation">>, <<>>],
                   escalus_connection:get_stanza(Alice, no_stream_error_stanza_received)),
    escalus:assert(is_stream_end,
                   escalus_connection:get_stanza(Alice, no_stream_end_stanza_received)),
    true = escalus_connection:wait_for_close(Alice, timer:seconds(1)).

return_proper_stream_error_if_service_is_not_hidden(_Config) ->
    % GIVEN MongooseIM is running default configuration
    % WHEN we send non-XMPP payload
    % THEN the server replies with stream error xml-not-well-formed and closes the connection
    SendMalformedDataStep = fun(Client, Features) ->
                                    escalus_connection:send_raw(Client, <<"malformed">>),
                                    {Client, Features}
                            end,
    {ok, Connection, _} = escalus_connection:start([{port, 6222}], [SendMalformedDataStep]),
    escalus_connection:receive_stanza(Connection, #{ assert => is_stream_start }),
    StreamErrorAssertion = {is_stream_error, [<<"xml-not-well-formed">>, <<>>]},
    escalus_connection:receive_stanza(Connection, #{ assert => StreamErrorAssertion }),
    %% Sometimes escalus needs a moment to report the connection as closed
    escalus_connection:wait_for_close(Connection, 5000).

close_connection_if_service_type_is_hidden(_Config) ->
    % GIVEN the option to hide service name is enabled
    % WHEN we send non-XMPP payload
    % THEN connection is closed without any response from the server
    FailIfAnyDataReturned = fun(Reply) ->
                                    ct:fail({unexpected_data, Reply})
                            end,
    Connection = escalus_tcp:connect(#{port => 6222, on_reply => FailIfAnyDataReturned }),
    Ref = monitor(process, Connection),
    escalus_tcp:send(Connection, <<"malformed">>),
    receive
        {'DOWN', Ref, _, _, _} -> ok
    after
        5000 ->
            ct:fail(connection_not_closed)
    end.

same_resource_replaces_session(Config) ->
    UserSpec = [{resource, <<"conflict">>} | escalus_fresh:create_fresh_user(Config, alice_m)],
    {ok, Alice1, _} = escalus_connection:start(UserSpec),
    {ok, Alice2, _} = escalus_connection:start(UserSpec),
    ConflictError = escalus:wait_for_stanza(Alice1),
    escalus:assert(is_stream_error, [<<"conflict">>, <<>>], ConflictError),
    mongoose_helper:wait_until(fun() -> escalus_connection:is_connected(Alice1) end, false),
    escalus_connection:stop(Alice2).

clean_close_of_replaced_session(Config) ->
    logger_ct_backend:capture(warning),
    same_resource_replaces_session(Config),
    logger_ct_backend:stop_capture(),
    FilterFun = fun(_, Msg) ->
                        re:run(Msg, "replaced_wait_timeout") /= nomatch
                end,
    [] = logger_ct_backend:recv(FilterFun).

replaced_session_cannot_terminate(Config) ->
    % GIVEN a session that is frozen and cannot terminate
    logger_ct_backend:capture(warning),
    UserSpec = [{resource, <<"conflict">>} | escalus_fresh:create_fresh_user(Config, alice_m)],
    {ok, Alice1, _} = escalus_connection:start(UserSpec),
    C2SPid = mongoose_helper:get_session_pid(Alice1),
    ok = rpc(mim(), sys, suspend, [C2SPid]),
    % WHEN a session gets replaced ...
    {ok, Alice2, _} = escalus_connection:start(UserSpec),
    % THEN a timeout warning is logged
    FilterFun = fun(_, Msg) -> re:run(Msg, "replaced_wait_timeout") /= nomatch end,
    mongoose_helper:wait_until(fun() -> length(logger_ct_backend:recv(FilterFun)) end, 1),
    rpc(mim(), sys, resume, [C2SPid]),
    logger_ct_backend:stop_capture(),
    escalus_connection:stop(Alice2).

cannot_connect_without_proxy_header(Config) ->
    UserSpec = escalus_fresh:create_fresh_user(Config, alice_m),
    ConnResult = escalus_connection:start(UserSpec, [start_stream]),
    ?assertMatch({error, {connection_step_failed, _, _}}, ConnResult).

connect_with_proxy_header(Config) ->
    UserSpec = escalus_fresh:create_fresh_user(Config, alice_m),
    ConnectionSteps = [{connect_SUITE, send_proxy_header},
                       start_stream, stream_features, authenticate, bind],
    {ok, Conn, _Features} = escalus_connection:start(UserSpec, ConnectionSteps),
    escalus:send(Conn, escalus_stanza:presence(<<"available">>)),
    escalus:assert(is_presence, escalus:wait_for_stanza(Conn)),
    % SessionInfo = mongoose_helper:get_session_info(mim(), Conn),
    % #{src_address := IPAddr, src_port := Port} = proxy_info(),
    % ?assertMatch({IPAddr, Port}, maps:get(ip, SessionInfo)),
    escalus_connection:stop(Conn).

%%--------------------------------------------------------------------
%% helpers
%%--------------------------------------------------------------------
m_listener(GroupName) ->
    Port = ct:get_config({hosts, mim, mc2s_port}),
    ExtraOpts = extra_listener_opts(GroupName),
    Listener = #{port => Port,
                 ip_tuple => {0,0,0,0},
                 ip_address => "0",
                 ip_version => 4,
                 proto => tcp,
                 proxy_protocol => false,
                 module => mongoose_c2s_listener},
    maps:merge(Listener, ExtraOpts).

extra_listener_opts(proxy_protocol) ->
    #{proxy_protocol => true};
extra_listener_opts(_) ->
    #{}.

proxy_info() ->
    #{version => 2,
      command => proxy,
      transport_family => ipv4,
      transport_protocol => stream,
      src_address => {1, 2, 3, 4},
      src_port => 444,
      dest_address => {192, 168, 0, 1},
      dest_port => 443
     }.
