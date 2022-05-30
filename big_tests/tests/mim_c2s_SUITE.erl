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
     {group, basic}
    ].

groups() ->
    [
     {basic, [parallel],
      [
       log_one
      ]}
    ].

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------
init_per_suite(Config) ->
    rpc(mim(), mongoose_listener, start_listener, [m_listener()]),
    escalus:init_per_suite(Config).

end_per_suite(Config) ->
    escalus_fresh:clean(),
    rpc(mim(), mongoose_listener, stop_listener, [m_listener()]),
    escalus:end_per_suite(Config).

init_per_group(_, Config) ->
    Config.

end_per_group(_, _Config) ->
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

%%--------------------------------------------------------------------
%% helpers
%%--------------------------------------------------------------------
m_listener() ->
    Port = ct:get_config({hosts, mim, mc2s_port}),
    #{port => Port,
      ip_tuple => {0,0,0,0},
      ip_address => "0",
      ip_version => 4,
      proto => tcp,
      module => mongoose_c2s_listener}.
