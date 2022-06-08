-module(mod_c2s_presence).

-behavior(gen_mod).

-export([start/2, stop/1, supported_features/0]).
-export([user_send_presence/3]).

-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
start(HostType, _Opts) ->
    gen_hook:add_handlers(c2s_hooks(HostType)).

-spec stop(mongooseim:host_type()) -> ok.
stop(HostType) ->
    gen_hook:delete_handlers(c2s_hooks(HostType)).

-spec supported_features() -> [atom()].
supported_features() ->
    [dynamic_domains].

-spec c2s_hooks(mongooseim:host_type()) -> gen_hook:hook_list(mongoose_c2s:handler_fn()).
c2s_hooks(HostType) ->
    [{user_send_presence, HostType, fun ?MODULE:user_send_presence/3, #{}, 50}].

-spec user_send_presence(mongoose_acc:t(), mongoose_c2s:handler_params(), map()) ->
    {ok, mongoose_acc:t()}.
user_send_presence(Acc, #{c2s := C2SState}, _Extra) ->
    {FromJid, ToJid, El} = mongoose_acc:packet(Acc),
    case jid:are_bare_equal(FromJid, ToJid) of
        true ->
            Acc1 = presence_update(Acc, FromJid, ToJid, El, C2SState),
            {ok, Acc1};
        _ ->
            {ok, Acc}
    end.

%% @doc User updates his presence (non-directed presence packet)
-spec presence_update(mongoose_acc:t(), jid:jid(), jid:jid(), exml:element(), mongoose_c2s:state()) ->
    mongoose_acc:t().
presence_update(Acc, FromJid, ToJid, El, State) ->
    case mongoose_acc:stanza_type(Acc) of
        undefined ->
            presence_update_to_available(Acc, FromJid, ToJid, El);
        <<"unavailable">> ->
            Status = exml_query:path(El, [{element, <<"status">>}, cdata], <<>>),
            ejabberd_sm:unset_presence(Acc, mongoose_c2s:get_sid(State), mongoose_c2s:get_jid(State), Status, #{});
        <<"error">> -> Acc;
        <<"probe">> -> Acc;
        <<"subscribe">> -> Acc;
        <<"subscribed">> -> Acc;
        <<"unsubscribe">> -> Acc;
        <<"unsubscribed">> -> Acc
    end.

presence_update_to_available(Acc, FromJid, ToJid, Packet) ->
    Acc1 = mongoose_hooks:user_available_hook(Acc, FromJid),
    presence_broadcast_first(Acc1, FromJid, ToJid, Packet).

presence_broadcast_first(Acc, FromJid, ToJid, Packet) ->
    ejabberd_router:route(FromJid, ToJid, Acc, Packet).
