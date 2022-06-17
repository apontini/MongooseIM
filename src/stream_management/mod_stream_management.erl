-module(mod_stream_management).
-xep([{xep, 198}, {version, "1.6"}]).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

%% `gen_mod' callbacks
-export([start/2,
         stop/1,
         config_spec/0,
         supported_features/0,
         process_buffer_and_ack/1]).

%% hooks handlers
-export([c2s_stream_features/3,
         remove_smid/5,
         session_cleanup/5]).

%% API for `ejabberd_c2s'
-export([make_smid/0,
         get_session_from_smid/2,
         get_buffer_max/1,
         get_ack_freq/1,
         get_resume_timeout/1,
         register_smid/3]).

-export([
         user_send_xmlel/3
        ]).

%% API for inspection and tests
-export([get_sid/2,
         get_stale_h/2,
         register_stale_smid_h/3,
         remove_stale_smid_h/2]).

-ignore_xref([c2s_stream_features/3, get_sid/2, get_stale_h/2, remove_smid/5,
              register_stale_smid_h/3, remove_stale_smid_h/2, session_cleanup/5]).

-type smid() :: base64:ascii_binary().

-export_type([smid/0]).

-include("mongoose.hrl").
-include("jlib.hrl").
-include("mongoose_config_spec.hrl").

-type handler() :: #{buffer_max := infinity | pos_integer(),
                     ack_freq := pos_integer(),
                     resume_timeout := pos_integer()}.

-type buffer_max() :: pos_integer() | infinity | no_buffer.
-type ack_freq() :: pos_integer() | never.
%%
%% `gen_mod' callbacks
%%

start(HostType, Opts) ->
    mod_stream_management_backend:init(HostType, Opts),
    ?LOG_INFO(#{what => stream_management_starting}),
    ejabberd_hooks:add(hooks(HostType)),
    gen_hook:add_handlers(c2s_hooks(HostType)),
    ok.

stop(HostType) ->
    ?LOG_INFO(#{what => stream_management_stopping}),
    gen_hook:delete_handlers(c2s_hooks(HostType)),
    ejabberd_hooks:delete(hooks(HostType)),
    ok.

hooks(HostType) ->
    [{sm_remove_connection_hook, HostType, ?MODULE, remove_smid, 50},
     {c2s_stream_features, HostType, ?MODULE, c2s_stream_features, 50},
     {session_cleanup, HostType, ?MODULE, session_cleanup, 50}].

-spec c2s_hooks(mongooseim:host_type()) -> gen_hook:hook_list(mongoose_c2s:hook_fn()).
c2s_hooks(HostType) ->
    [
     {user_send_xmlel, HostType, fun ?MODULE:user_send_xmlel/3, #{}, 100}
    ].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
        items = #{<<"backend">> => #option{type = atom, validate = {module, ?MODULE}},
                  <<"buffer">> => #option{type = boolean},
                  <<"buffer_max">> => #option{type = int_or_infinity,
                                              validate = positive},
                  <<"ack">> => #option{type = boolean},
                  <<"ack_freq">> => #option{type = integer,
                                            validate = positive},
                  <<"resume_timeout">> => #option{type = integer,
                                                  validate = positive},
                  <<"stale_h">> => stale_h_config_spec()
                 },
        process = fun ?MODULE:process_buffer_and_ack/1,
        defaults = #{<<"backend">> => mnesia,
                     <<"buffer">> => true,
                     <<"buffer_max">> => 100,
                     <<"ack">> => true,
                     <<"ack_freq">> => 1,
                     <<"resume_timeout">> => 600 % seconds
        }
      }.

supported_features() -> [dynamic_domains].

process_buffer_and_ack(Opts = #{buffer := Buffer, ack := Ack}) ->
    OptsWithBuffer = check_buffer(Buffer, Opts),
    check_ack(Ack, OptsWithBuffer).

check_buffer(false, Opts) ->
    Opts#{buffer_max => no_buffer};
check_buffer(_, Opts) ->
    Opts.

check_ack(false, Opts) ->
    Opts#{ack_freq => never};
check_ack(_, Opts) ->
    Opts.

stale_h_config_spec() ->
    #section{
        items = #{<<"enabled">> => #option{type = boolean},
                  <<"repeat_after">> => #option{type = integer,
                                                validate = positive},
                  <<"geriatric">> => #option{type = integer,
                                             validate = positive}},
        include = always,
        defaults = #{<<"enabled">> => false,
                     <<"repeat_after">> => 1800, % seconds
                     <<"geriatric">> => 3600 % seconds
        }
    }.

%%
%% hooks handlers
%%

-spec user_send_xmlel(Acc, Params, Extra) -> Result when
      Acc :: mongoose_acc:t(),
      Params :: mongoose_c2s:hook_params(),
      Extra :: map(),
      Result :: {ok, mongoose_acc:t()}.
user_send_xmlel(Acc, Params, _Extra) ->
    El = mongoose_acc:element(Acc),
    case exml_query:attr(El, <<"xmlns">>) of
        ?NS_STREAM_MGNT_3 ->
            handle_stream_mgnt(Acc, Params, El);
        _ -> {ok, Acc}
    end.

-spec handle_stream_mgnt(mongoose_acc:t(), mongoose_c2s:hook_params(), exml:element()) ->
    {ok | stop, mongoose_acc:t()}.
handle_stream_mgnt(Acc, Params = #{c2s_state := session_established}, #xmlel{name = <<"r">>}) ->
    handle_r(Acc, Params);
handle_stream_mgnt(Acc, Params = #{c2s_state := session_established}, El = #xmlel{name = <<"a">>}) ->
    handle_a(Acc, Params, El);
handle_stream_mgnt(Acc, #{c2s_state := {wait_for_feature_after_auth, _Retries}}, #xmlel{name = <<"resume">>}) ->
    %% TODO: handle resume session
    {ok, Acc};
handle_stream_mgnt(Acc, #{c2s_state := session_established}, #xmlel{name = <<"resume">>}) ->
    %% TODO: handle resume session
    {ok, Acc};
handle_stream_mgnt(Acc, Params = #{c2s_state := session_established}, El = #xmlel{name = <<"enable">>}) ->
    handle_enable(Acc, Params, El);

handle_stream_mgnt(Acc, #{c2s_state := {wait_for_feature_after_auth, 0}},
                   #xmlel{name = <<"enable">>}) ->
    {stop, mongoose_acc:set(c2s, stop, retries, Acc)};
handle_stream_mgnt(Acc, #{c2s_state := {wait_for_sasl_response, _, 0}},
                   #xmlel{name = <<"enable">>}) ->
    {stop, mongoose_acc:set(c2s, stop, retries, Acc)};
handle_stream_mgnt(Acc, #{c2s_state := {wait_for_feature_before_auth, _, 0}},
                   #xmlel{name = <<"enable">>}) ->
    {stop, mongoose_acc:set(c2s, stop, retries, Acc)};
handle_stream_mgnt(Acc, #{c2s_state := {wait_for_feature_after_auth, Retries}},
                   #xmlel{name = <<"enable">>}) ->
    unexpected_sm_request(Acc, {wait_for_feature_after_auth, Retries - 1});
handle_stream_mgnt(Acc, #{c2s_state := {wait_for_feature_before_auth, SaslState, Retries}},
                   #xmlel{name = <<"enable">>}) ->
    unexpected_sm_request(Acc, {wait_for_feature_before_auth, SaslState, Retries - 1});
handle_stream_mgnt(Acc, #{c2s_state := {wait_for_sasl_response, SaslState, Retries}},
                   #xmlel{name = <<"enable">>}) ->
    unexpected_sm_request(Acc, {wait_for_sasl_response, SaslState, Retries - 1});
handle_stream_mgnt(Acc, _Params, _El) ->
    {ok, Acc}.

-spec handle_r(mongoose_acc:t(), mongoose_c2s:hook_params()) ->
    {ok | stop, mongoose_acc:t()}.
handle_r(Acc, #{c2s_data := C2SState}) ->
    case get_sm_handler(C2SState) of
        {error, not_found} ->
            ?LOG_WARNING(#{what => unexpected_r, c2s_state => C2SState,
                           text => <<"received <r/> but stream management is off!">>});
        #{counter_in := In} ->
            Stanza = stream_mgmt_ack(In),
            mongoose_c2s:send_element_from_server_jid(C2SState, Stanza)
    end,
    {ok, Acc}.

    %% TODO: handle stream management acknowledgements
-spec handle_a(mongoose_acc:t(), mongoose_c2s:hook_params(), exml:element()) ->
    {ok | stop, mongoose_acc:t()}.
handle_a(Acc, #{c2s_data := C2SState}, El) ->
    case {get_sm_handler(C2SState), stream_mgmt_parse_h(El)} of
        {{error, not_found}, _} ->
            ?LOG_WARNING(#{what => unexpected_r, c2s_state => C2SState,
                           text => <<"received <r/> but stream management is off!">>}),
            {ok, Acc};
        {_, invalid_h_attribute} ->
            Stanza = mongoose_xmpp_errors:policy_violation(?MYLANG, <<"Invalid h attribute">>),
            mongoose_c2s:c2s_stream_error(C2SState, Stanza),
            {stop, mongoose_acc:set(c2s, stop, {shutdown, invalid_h_attribute}, Acc)};
        {#{counter_in := In}, _} ->
            {ok, Acc}
    end.

-spec handle_enable(mongoose_acc:t(), mongoose_c2s:hook_params(), exml:element()) ->
    {ok | stop, mongoose_acc:t()}.
handle_enable(Acc, #{c2s_data := C2SState}, El) ->
    case {get_sm_handler(C2SState), exml_query:attr(El, <<"resume">>, false)} of
        {{error, not_found}, <<"true">>} ->
            do_handle_enable(Acc, C2SState, true);
        {{error, not_found}, <<"1">>} ->
            do_handle_enable(Acc, C2SState, true);
        {{error, not_found}, false} ->
            do_handle_enable(Acc, C2SState, false);
        {{error, not_found}, _InvalidResumeAttr} ->
            Action = {next_event, internal, {stream_error, fun sm_handler/2}},
            {stop, mongoose_acc:append(c2s, actions, Action, Acc)};
        {#{}, _} ->
            Action = {next_event, internal, {stream_error, fun sm_handler/2}},
            {stop, mongoose_acc:append(c2s, actions, Action, Acc)}
    end.

-spec do_handle_enable(mongoose_acc:t(), mongoose_c2s:state(), boolean()) ->
    {ok | stop, mongoose_acc:t()}.
do_handle_enable(Acc, C2SState, Resume) ->
    HostType = mongoose_acc:host_type(Acc),
    #{buffer_max := _BufferMax, ack_freq := _AckFreq, resume_timeout := _ResumeTimeout}
        = ModOpts = gen_mod:get_module_opts(HostType, ?MODULE),
    SmHandlers = #{?MODULE => ModOpts#{buffer => [], counter_in => 0, counter_out => 0}},
    case Resume of
        true ->
            SMID = make_smid(),
            Sid = mongoose_c2s:get_sid(C2SState),
            HostType = mongoose_c2s:get_host_type(C2SState),
            ok = register_smid(HostType, SMID, Sid),
            Stanza = stream_mgmt_enabled([{<<"id">>, SMID}, {<<"resume">>, <<"true">>}]),
            mongoose_c2s:send_element_from_server_jid(C2SState, Stanza);
        false ->
            Stanza = stream_mgmt_enabled(),
            mongoose_c2s:send_element_from_server_jid(C2SState, Stanza)
    end,
    {ok, mongoose_acc:merge(c2s, handlers, SmHandlers, Acc)}.

-spec unexpected_sm_request(mongoose_acc:t(), mongoose_c2s:fsm_state()) ->
    {ok, mongoose_acc:t()}.
unexpected_sm_request(Acc, NewState) ->
    Action = {next_event, internal, {unexpected_sm_request, fun sm_handler/2}},
    Acc1 = mongoose_acc:set(c2s, fsm_state, NewState, Acc),
    {stop, mongoose_acc:append(c2s, actions, Action, Acc1)}.

sm_handler(unexpected_sm_request, C2SState) ->
    Err = stream_mgmt_failed(<<"unexpected-request">>),
    mongoose_c2s:send_element_from_server_jid(C2SState, Err),
    #{};
sm_handler(stream_error, C2SState) ->
    Err = stream_mgmt_failed(<<"unexpected-request">>),
    mongoose_c2s:c2s_stream_error(C2SState, Err),
    #{stop => {shutdown, stream_error}}.

-spec get_sm_handler(mongoose_c2s:state()) -> handler().
get_sm_handler(C2SState) ->
    mongoose_c2s:get_handler(C2SState, ?MODULE).

-spec stream_mgmt_parse_h(exml:element()) -> invalid_h_attribute | integer().
stream_mgmt_parse_h(El) ->
    case catch binary_to_integer(exml_query:attr(El, <<"h">>)) of
        H when is_integer(H) -> H;
        _ -> invalid_h_attribute
    end.

-spec c2s_stream_features([exml:element()], mongooseim:host_type(), jid:lserver()) ->
          [exml:element()].
c2s_stream_features(Acc, _HostType, _Lserver) ->
    lists:keystore(<<"sm">>, #xmlel.name, Acc, sm()).

sm() ->
    #xmlel{name = <<"sm">>,
           attrs = [{<<"xmlns">>, ?NS_STREAM_MGNT_3}]}.

-spec remove_smid(Acc, SID, JID, Info, Reason) -> Acc1 when
      Acc :: mongoose_acc:t(),
      SID :: ejabberd_sm:sid(),
      JID :: undefined | jid:jid(),
      Info :: undefined | [any()],
      Reason :: undefined | ejabberd_sm:close_reason(),
      Acc1 :: mongoose_acc:t().
remove_smid(Acc, SID, _JID, _Info, _Reason) ->
    HostType = mongoose_acc:host_type(Acc),
    do_remove_smid(Acc, HostType, SID).

-spec session_cleanup(Acc :: map(), LUser :: jid:luser(), LServer :: jid:lserver(),
                      LResource :: jid:lresource(), SID :: ejabberd_sm:sid()) -> any().
session_cleanup(Acc, _LUser, _LServer, _LResource, SID) ->
    HostType = mongoose_acc:host_type(Acc),
    do_remove_smid(Acc, HostType, SID).

-spec do_remove_smid(mongoose_acc:t(), mongooseim:host_type(), ejabberd_sm:sid()) ->
    mongoose_acc:t().
do_remove_smid(Acc, HostType, SID) ->
    H = mongoose_acc:get(stream_mgmt, h, undefined, Acc),
    MaybeSMID = unregister_smid(HostType, SID),
    case MaybeSMID of
        {ok, SMID} when H =/= undefined ->
            register_stale_smid_h(HostType, SMID, H);
        _ ->
            ok
    end,
    mongoose_acc:set(stream_mgmt, smid, MaybeSMID, Acc).

%%
%% API for `ejabberd_c2s'
%%

-spec make_smid() -> smid().
make_smid() ->
    base64:encode(crypto:strong_rand_bytes(21)).

-spec stream_mgmt_enabled() -> exml:element().
stream_mgmt_enabled() ->
    stream_mgmt_enabled([]).

-spec stream_mgmt_enabled([exml:attr()]) -> exml:element().
stream_mgmt_enabled(ExtraAttrs) ->
    #xmlel{name = <<"enabled">>,
           attrs = [{<<"xmlns">>, ?NS_STREAM_MGNT_3}] ++ ExtraAttrs}.

-spec stream_mgmt_failed(binary()) -> exml:element().
stream_mgmt_failed(Reason) ->
    stream_mgmt_failed(Reason, []).

-spec stream_mgmt_failed(binary(), [exml:attr()]) -> exml:element().
stream_mgmt_failed(Reason, Attrs) ->
    ReasonEl = #xmlel{name = Reason,
                      attrs = [{<<"xmlns">>, ?NS_STANZAS}]},
    #xmlel{name = <<"failed">>,
           attrs = [{<<"xmlns">>, ?NS_STREAM_MGNT_3} | Attrs],
           children = [ReasonEl]}.

-spec stream_mgmt_ack(pos_integer()) -> exml:element().
stream_mgmt_ack(NIncoming) ->
    #xmlel{name = <<"a">>,
           attrs = [{<<"xmlns">>, ?NS_STREAM_MGNT_3},
                    {<<"h">>, integer_to_binary(NIncoming)}]}.

%% Getters
-spec get_session_from_smid(mongooseim:host_type(), smid()) ->
    {sid, ejabberd_sm:sid()} | {stale_h, non_neg_integer()} | {error, smid_not_found}.
get_session_from_smid(HostType, SMID) ->
    case get_sid(HostType, SMID) of
        {sid, SID} -> {sid, SID};
        {error, smid_not_found} -> get_stale_h(HostType, SMID)
    end.

-spec get_stale_h(mongooseim:host_type(), SMID :: smid()) ->
    {stale_h, non_neg_integer()} | {error, smid_not_found}.
get_stale_h(HostType, SMID) ->
    case is_stale_h_enabled(HostType) of
        false -> {error, smid_not_found};
        true -> read_stale_h(HostType, SMID)
    end.

-spec get_buffer_max(mongooseim:host_type()) -> buffer_max().
get_buffer_max(HostType) ->
    gen_mod:get_module_opt(HostType, ?MODULE, buffer_max).

-spec get_ack_freq(mongooseim:host_type()) -> ack_freq().
get_ack_freq(HostType) ->
    gen_mod:get_module_opt(HostType, ?MODULE, ack_freq).

-spec get_resume_timeout(mongooseim:host_type()) -> pos_integer().
get_resume_timeout(HostType) ->
    gen_mod:get_module_opt(HostType, ?MODULE, resume_timeout).


register_stale_smid_h(HostType, SMID, H) ->
    case is_stale_h_enabled(HostType) of
        false -> ok;
        true -> write_stale_h(HostType, SMID, H)
    end.

remove_stale_smid_h(HostType, SMID) ->
    case is_stale_h_enabled(HostType) of
        false -> ok;
        true -> delete_stale_h(HostType, SMID)
    end.

is_stale_h_enabled(HostType) ->
    gen_mod:get_module_opt(HostType, ?MODULE, [stale_h, enabled]).

%% Backend operations

-spec register_smid(HostType, SMID, SID) ->
    ok | {error, term()} when
    HostType :: mongooseim:host_type(),
    SMID :: mod_stream_management:smid(),
    SID :: ejabberd_sm:sid().
register_smid(HostType, SMID, SID) ->
    mod_stream_management_backend:register_smid(HostType, SMID, SID).

-spec unregister_smid(mongooseim:host_type(), ejabberd_sm:sid()) ->
    {ok, SMID :: mod_stream_management:smid()} | {error, smid_not_found}.
unregister_smid(HostType, SID) ->
    mod_stream_management_backend:unregister_smid(HostType, SID).

-spec get_sid(mongooseim:host_type(), mod_stream_management:smid()) ->
    {sid, ejabberd_sm:sid()} | {error, smid_not_found}.
get_sid(HostType, SMID) ->
    mod_stream_management_backend:get_sid(HostType, SMID).

%% stale_h

-spec write_stale_h(HostType, SMID, H) -> ok | {error, any()} when
    HostType :: mongooseim:host_type(),
    SMID :: mod_stream_management:smid(),
    H :: non_neg_integer().
write_stale_h(HostType, SMID, H) ->
    mod_stream_management_backend:write_stale_h(HostType, SMID, H).

-spec delete_stale_h(HostType, SMID) -> ok | {error, any()} when
    HostType :: mongooseim:host_type(),
    SMID :: mod_stream_management:smid().
delete_stale_h(HostType, SMID) ->
    mod_stream_management_backend:delete_stale_h(HostType, SMID).

-spec read_stale_h(HostType, SMID) ->
    {stale_h, non_neg_integer()} | {error, smid_not_found} when
    HostType :: mongooseim:host_type(),
    SMID :: mod_stream_management:smid().
read_stale_h(HostType, SMID) ->
    mod_stream_management_backend:read_stale_h(HostType, SMID).
