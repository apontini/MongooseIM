-module(mongoose_client_api_contacts).
-behaviour(cowboy_rest).

-export([trails/0]).
-export([init/2]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([is_authorized/2]).
-export([allowed_methods/2]).

-export([forbidden_request/2]).

-export([to_json/2]).
-export([from_json/2]).
-export([delete_resource/2]).

-ignore_xref([from_json/2, to_json/2, trails/0, forbidden_request/2]).

-include("mongoose.hrl").
-include("jlib.hrl").
-include_lib("exml/include/exml.hrl").

trails() ->
    mongoose_client_api_contacts_doc:trails().

init(Req, Opts) ->
    mongoose_client_api:init(Req, Opts).

is_authorized(Req, State) ->
    mongoose_client_api:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {[
      {{<<"application">>, <<"json">>, '*'}, to_json}
     ], Req, State}.

content_types_accepted(Req, State) ->
    {[
      {{<<"application">>, <<"json">>, '*'}, from_json}
     ], Req, State}.

allowed_methods(Req, State) ->
    {[<<"OPTIONS">>, <<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>],
     Req, State}.

forbidden_request(Req, State) ->
    Req1 = cowboy_req:reply(403, Req),
    {stop, Req1, State}.

to_json(Req, #{jid := Caller} = State) ->
    CJid = jid:to_binary(Caller),
    Method = cowboy_req:method(Req),
    Jid = cowboy_req:binding(jid, Req),
    case Jid of
        undefined ->
            {ok, Res} = handle_request(Method, Jid, undefined, CJid, State),
            {jiffy:encode(lists:flatten([Res])), Req, State};
        _ ->
            Req2 = cowboy_req:reply(404, Req),
            {stop, Req2, State}
    end.


from_json(Req, #{jid := Caller} = State) ->
    CJid = jid:to_binary(Caller),
    Method = cowboy_req:method(Req),
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    case mongoose_client_api:json_to_map(Body) of
        {ok, JSONData} ->
            Jid = case maps:get(<<"jid">>, JSONData, undefined) of
                      undefined -> cowboy_req:binding(jid, Req1);
                      J when is_binary(J) -> J;
                      _ -> undefined
                  end,
            Action = maps:get(<<"action">>, JSONData, undefined),
            handle_request_and_respond(Method, Jid, Action, CJid, Req1, State);
        _ ->
            mongoose_client_api:bad_request(Req1, State)
    end.

%% @doc Called for a method of type "DELETE"
delete_resource(Req, #{jid := Caller} = State) ->
    CJid = jid:to_binary(Caller),
    Jid = cowboy_req:binding(jid, Req),
    case Jid of
        undefined ->
            handle_multiple_deletion(CJid, get_requested_contacts(Req), Req, State);
        _ ->
            handle_single_deletion(CJid, Jid, Req, State)
    end.

handle_multiple_deletion(_, undefined, Req, State) ->
    mongoose_client_api:bad_request(Req, State);
handle_multiple_deletion(CJid, ToDelete, Req, State) ->
    case handle_request(<<"DELETE">>, ToDelete, undefined, CJid, State) of
        {ok, NotDeleted} ->
            RespBody = #{not_deleted => NotDeleted},
            Req2 = cowboy_req:set_resp_body(jiffy:encode(RespBody), Req),
            Req3 = cowboy_req:set_resp_header(<<"content-type">>, <<"application/json">>, Req2),
            {true, Req3, State};
        Other ->
            serve_failure(Other, Req, State)
    end.

handle_single_deletion(_, undefined, Req, State) ->
    mongoose_client_api:bad_request(Req, State);
handle_single_deletion(CJid, ToDelete, Req, State) ->
    case handle_request(<<"DELETE">>, ToDelete, undefined, CJid, State) of
        ok ->
            {true, Req, State};
        Other ->
            serve_failure(Other, Req, State)
    end.

handle_request_and_respond(_, undefined, _, _, Req, State) ->
    mongoose_client_api:bad_request(Req, State);
handle_request_and_respond(Method, Jid, Action, CJid, Req, State) ->
    case handle_request(Method, to_binary(Jid), Action, CJid, State) of
        ok ->
            {true, Req, State};
        not_implemented ->
            Req2 = cowboy_req:reply(501, Req),
            {stop, Req2, State};
        not_found ->
            Req2 = cowboy_req:reply(404, Req),
            {stop, Req2, State}
    end.

serve_failure(not_implemented, Req, State) ->
    Req2 = cowboy_req:reply(501, Req),
    {stop, Req2, State};
serve_failure(not_found, Req, State) ->
    Req2 = cowboy_req:reply(404, Req),
    {stop, Req2, State};
serve_failure({error, ErrorType, Msg}, Req, State) ->
    ?LOG_ERROR(#{what => api_contacts_error,
                 text => <<"Error while serving http request. Return code 500">>,
                 error_type => ErrorType, msg => Msg, req => Req}),
    Req2 = cowboy_req:reply(500, Req),
    {stop, Req2, State}.

get_requested_contacts(Req) ->
    Body = get_whole_body(Req, <<"">>),
    case mongoose_client_api:json_to_map(Body) of
        {ok, #{<<"to_delete">> :=  ResultJids}} when is_list(ResultJids) ->
            case [X || X <- ResultJids, is_binary(X)] =:= ResultJids of
                true ->
                    ResultJids;
                false ->
                    undefined
            end;
        _ ->
            undefined
    end.

get_whole_body(Req, Acc) ->
    case cowboy_req:read_body(Req) of
        {ok, Data, _Req2} ->
            <<Data/binary, Acc/binary>>;
        {more, Data, Req2} ->
            get_whole_body(Req2, <<Data/binary, Acc/binary>>)
    end.

handle_request(<<"GET">>, undefined, undefined, CJid, _State) ->
    list_contacts(CJid);
handle_request(<<"POST">>, Jid, undefined, CJid, _State) ->
    add_contact(CJid, Jid);
handle_request(<<"DELETE">>, Jids, _Action, CJid, _State) when is_list(Jids) ->
    delete_contacts(CJid, Jids);
handle_request(Method, Jid, Action, CJid, #{jid := CallerJid, creds := Creds}) ->
    HostType = mongoose_credentials:host_type(Creds),
    case contact_exists(HostType, CallerJid, jid:from_binary(Jid)) of
        true ->
            handle_contact_request(Method, Jid, Action, CJid);
        false -> not_found
    end.

handle_contact_request(<<"PUT">>, Jid, <<"invite">>, CJid) ->
    subscription(CJid, Jid, atom_to_binary(subscribe, latin1));
handle_contact_request(<<"PUT">>, Jid, <<"accept">>, CJid) ->
    subscription(CJid, Jid, atom_to_binary(subscribed, latin1));
handle_contact_request(<<"DELETE">>, Jid, undefined, CJid) ->
    delete_contact(CJid, Jid);
handle_contact_request(_, _, _, _) ->
    not_implemented.

to_binary(S) when is_binary(S) ->
    S;
to_binary(S) ->
    list_to_binary(S).

-spec contact_exists(mongooseim:host_type(), jid:jid(), jid:jid() | error) -> boolean().
contact_exists(_, _, error) -> false;
contact_exists(HostType, CallerJid, Jid) ->
    LJid = jid:to_lower(Jid),
    Res = mod_roster:get_roster_entry(HostType, CallerJid, LJid, short),
    Res =/= does_not_exist andalso Res =/= error.

%% Internal functions

list_contacts(Caller) ->
    case mod_roster_api:list_contacts(jid:from_binary(Caller)) of
        {ok, Rosters} ->
            {ok, [roster_info(mod_roster:item_to_map(R)) || R <- Rosters]};
        Error ->
            skip_result_msg(Error)
    end.

roster_info(M) ->
    Jid = jid:to_binary(maps:get(jid, M)),
    #{subscription := Sub, ask := Ask} = M,
    #{jid => Jid, subscription => Sub, ask => Ask}.

skip_result_msg({ok, _Msg}) -> ok;
skip_result_msg({ErrCode, _Msg}) -> {error, ErrCode}.

add_contact(Caller, JabberID) ->
    add_contact(Caller, JabberID, <<>>, []).

add_contact(Caller, Other, Name, Groups) ->
    case mongoose_stanza_helper:parse_from_to(Caller, Other) of
        {ok, CallerJid, OtherJid} ->
            Res = mod_roster_api:add_contact(CallerJid, OtherJid, Name, Groups),
            skip_result_msg(Res);
        E ->
            E
    end.

delete_contacts(Caller, ToDelete) ->
    maybe_delete_contacts(Caller, ToDelete, []).

maybe_delete_contacts(_, [], NotDeleted) -> NotDeleted;
maybe_delete_contacts(Caller, [H | T], NotDeleted) ->
    case delete_contact(Caller, H) of
        ok ->
            maybe_delete_contacts(Caller, T, NotDeleted);
        _Error ->
            maybe_delete_contacts(Caller, T, NotDeleted ++ [H])
    end.

delete_contact(Caller, Other) ->
    case mongoose_stanza_helper:parse_from_to(Caller, Other) of
        {ok, CallerJID, OtherJID} ->
            Res = mod_roster_api:delete_contact(CallerJID, OtherJID),
            skip_result_msg(Res);
        E ->
            E
    end.

subscription(Caller, Other, Action) ->
    case decode_action(Action) of
        error ->
            {error, bad_request, <<"invalid action">>};
        Act ->
            case mongoose_stanza_helper:parse_from_to(Caller, Other) of
                {ok, CallerJID, OtherJID} ->
                    Res = mod_roster_api:subscription(CallerJID, OtherJID, Act),
                    skip_result_msg(Res);
                E ->
                    E
            end
    end.

decode_action(<<"subscribe">>) -> subscribe;
decode_action(<<"subscribed">>) -> subscribed;
decode_action(_) -> error.
