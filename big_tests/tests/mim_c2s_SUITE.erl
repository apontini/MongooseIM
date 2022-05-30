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
     {group, incorrect_behaviors}
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

init_per_group(GroupName, Config) ->
    rpc(mim(), mongoose_listener, start_listener, [m_listener(GroupName)]),
    Config.

end_per_group(GroupName, _Config) ->
    rpc(mim(), mongoose_listener, stop_listener, [m_listener(GroupName)]),
    ok.

init_per_testcase(Name, Config) ->
    escalus:init_per_testcase(Name, Config).

end_per_testcase(Name, Config) ->
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
