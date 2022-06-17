-module(mongoose_c2s_hooks).

-type hook_result() :: {ok | stop, mongoose_acc:t()}.

-export([user_send_packet/3,
         user_send_message/3,
         user_send_iq/3,
         user_send_presence/3,
         user_send_xmlel/3
        ]).

-spec user_send_packet(HostType, Acc, Params) -> Result when
    HostType :: mongooseim:host_type(),
    Acc :: mongoose_acc:t(),
    Params :: mongoose_c2s:handler_params(),
    Result :: hook_result().
user_send_packet(HostType, Acc, Params) ->
    {From, To, El} = mongoose_acc:packet(Acc),
    Args = [From, To, El],
    ParamsWithLegacyArgs = ejabberd_hooks:add_args(Params, Args),
    gen_hook:run_fold(user_send_packet, HostType, Acc, ParamsWithLegacyArgs).

-spec user_send_message(HostType, Acc, Params) -> Result when
    HostType :: mongooseim:host_type(),
    Acc :: mongoose_acc:t(),
    Params :: mongoose_c2s:handler_params(),
    Result :: hook_result().
user_send_message(HostType, Acc, Params) ->
    gen_hook:run_fold(user_send_message, HostType, Acc, Params).

-spec user_send_iq(HostType, Acc, Params) -> Result when
    HostType :: mongooseim:host_type(),
    Acc :: mongoose_acc:t(),
    Params :: mongoose_c2s:handler_params(),
    Result :: hook_result().
user_send_iq(HostType, Acc, Params) ->
    gen_hook:run_fold(user_send_iq, HostType, Acc, Params).

-spec user_send_presence(HostType, Acc, Params) -> Result when
    HostType :: mongooseim:host_type(),
    Acc :: mongoose_acc:t(),
    Params :: mongoose_c2s:handler_params(),
    Result :: hook_result().
user_send_presence(HostType, Acc, Params) ->
    gen_hook:run_fold(user_send_presence, HostType, Acc, Params).

-spec user_send_xmlel(HostType, Acc, Params) -> Result when
    HostType :: mongooseim:host_type(),
    Acc :: mongoose_acc:t(),
    Params :: mongoose_c2s:handler_params(),
    Result :: hook_result().
user_send_xmlel(HostType, Acc, Params) ->
    gen_hook:run_fold(user_send_xmlel, HostType, Acc, Params).
