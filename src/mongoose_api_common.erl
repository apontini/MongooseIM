%%%-------------------------------------------------------------------
%%% @author ludwikbukowski
%%% @copyright (C) 2016, Erlang Solutions Ltd.
%%% Created : 20. Jul 2016 10:16
%%%-------------------------------------------------------------------

%% @doc MongooseIM REST API backend
%%
%% This module handles the client HTTP REST requests, then respectively convert
%% them to Commands from mongoose_commands and execute with `admin` privileges.
%% It supports responses with appropriate HTTP Status codes returned to the
%% client.
%% This module implements behaviour introduced in ejabberd_cowboy which is
%% %% built on top of the cowboy library.
%% The method supported: GET, POST, PUT, DELETE. Only JSON format.
%% The library "jiffy" used to serialize and deserialized JSON data.
%%
%% REQUESTS
%%
%% The module is based on mongoose_commands registry.
%% The root http path for a command is build based on the "category" field.
%% %% It's always used as path a prefix.
%% The commands are translated to HTTP API in the following manner:
%%
%% command of action "read" will be called by GET request
%% command of action "create" will be called by POST request
%% command of action "update" will be called by PUT request
%% command of action "delete" will be called by DELETE request
%%
%% The args of the command will be filled with the values provided in path
%% %% bindings or body parameters, depending of the method type:
%% - for command of action "read" or "delete" all the args are pulled from the
%% path bindings. The path should be constructed of pairs "/arg_name/arg_value"
%% so that it could match the {arg_name, type} %% pattern in the command
%% registry. E.g having the record of category "users" and args:
%% [{username, binary}, {domain, binary}] we will have to make following GET
%% request %% path: http://domain:port/api/users/username/Joe/domain/localhost
%% and the command will be called with arguments "Joe" and "localhost"
%%
%% - for command of action "create" or "update" args are pulled from the body
%% JSON, except those that are on the "identifiers" list of the command. Those
%% go to the path bindings.
%% E.g having the record of category "animals", action "update" and args:
%% [{species, binary}, {name, binary}, {age, integer}]
%% and identifiers:
%% [species, name]
%% we can set the age for our elephant Ed in the PUT request:
%% path: http://domain:port/api/species/elephant/name/Ed
%% body: {"age" : "10"}
%% and then the command will be called with arguments ["elephant", "Ed" and 10].
%%
%% RESPONSES
%%
%% The API supports some of the http status code like 200, 201, 400, 404 etc
%% depending on the return value of the command execution and arguments checks.
%% Additionally, when the command's action is "create" and it returns a value,
%% it is concatenated to the path and return to the client in header "location"
%% with response code 201 so that it could represent now a new created resource.
%% If error occured while executing the command, the appropriate reason is
%% returned in response body.

-module(mongoose_api_common).
-author("ludwikbukowski").
-include("mongoose_api.hrl").
-include("mongoose.hrl").

%% API
-export([create_admin_url_path/1,
         create_user_url_path/1,
         action_to_method/1,
         method_to_action/1,
         parse_request_body/1,
         get_allowed_methods/1,
         process_request/4,
         reload_dispatches/1,
         get_auth_details/1,
         is_known_auth_method/1,
         error_response/4,
         make_unauthorized_response/2]).

-ignore_xref([reload_dispatches/1]).

%% @doc Reload all ejabberd_cowboy listeners.
%% When a command is registered or unregistered, the routing paths that
%% cowboy stores as a "dispatch" must be refreshed.
%% Read more http://ninenines.eu/docs/en/cowboy/1.0/guide/routing/
reload_dispatches(drop) ->
    drop;
reload_dispatches(_Command) ->
    Listeners = supervisor:which_children(mongoose_listener_sup),
    CowboyListeners = [Child || {_Id, Child, _Type, [ejabberd_cowboy]}  <- Listeners],
    [ejabberd_cowboy:reload_dispatch(Child) || Child <- CowboyListeners],
    drop.


-spec create_admin_url_path(mongoose_commands:t()) -> ejabberd_cowboy:path().
create_admin_url_path(Command) ->
    iolist_to_binary(create_admin_url_path_iodata(Command)).

create_admin_url_path_iodata(Command) ->
    ["/", mongoose_commands:category(Command),
          maybe_add_bindings(Command, admin), maybe_add_subcategory(Command)].

-spec create_user_url_path(mongoose_commands:t()) -> ejabberd_cowboy:path().
create_user_url_path(Command) ->
    iolist_to_binary(create_user_url_path_iodata(Command)).

create_user_url_path_iodata(Command) ->
    ["/", mongoose_commands:category(Command), maybe_add_bindings(Command, user)].

-spec process_request(Method :: method(),
                      Command :: mongoose_commands:t(),
                      Req :: cowboy_req:req() | {list(), cowboy_req:req()},
                      State :: http_api_state()) ->
                      {any(), cowboy_req:req(), http_api_state()}.
process_request(Method, Command, Req, #http_api_state{bindings = Binds, entity = Entity} = State)
    when ((Method == <<"POST">>) or (Method == <<"PUT">>)) ->
    {Params, Req2} = Req,
    QVals = cowboy_req:parse_qs(Req2),
    QV = [{binary_to_existing_atom(K, utf8), V} || {K, V} <- QVals],
    Params2 = Binds ++ Params ++ QV ++ maybe_add_caller(Entity),
    handle_request(Method, Command, Params2, Req2, State);
process_request(Method, Command, Req, #http_api_state{bindings = Binds, entity = Entity}=State)
    when ((Method == <<"GET">>) or (Method == <<"DELETE">>)) ->
    QVals = cowboy_req:parse_qs(Req),
    QV = [{binary_to_existing_atom(K, utf8), V} || {K, V} <- QVals],
    BindsAndVars = Binds ++ QV ++ maybe_add_caller(Entity),
    handle_request(Method, Command, BindsAndVars, Req, State).

-spec handle_request(Method :: method(),
                     Command :: mongoose_commands:t(),
                     Args :: args_applied(),
                     Req :: cowboy_req:req(),
                     State :: http_api_state()) ->
    {any(), cowboy_req:req(), http_api_state()}.
handle_request(Method, Command, Args, Req, #http_api_state{entity = Entity} = State) ->
    case check_and_extract_args(mongoose_commands:args(Command),
                                mongoose_commands:optargs(Command), Args) of
        {error, Type, Reason} ->
            handle_result(Method, {error, Type, Reason}, Req, State);
        ConvertedArgs ->
            handle_result(Method,
                          execute_command(ConvertedArgs, Command, Entity),
                          Req, State)
    end.

-type correct_result() :: mongoose_commands:success().
-type error_result() ::  mongoose_commands:failure().

-spec handle_result(Method, Result, Req, State) -> Return when
      Method :: method() | no_call,
      Result :: correct_result() | error_result(),
      Req :: cowboy_req:req(),
      State :: http_api_state(),
      Return :: {any(), cowboy_req:req(), http_api_state()}.
handle_result(<<"DELETE">>, ok, Req, State) ->
    Req2 = cowboy_req:reply(204, Req),
    {stop, Req2, State};
handle_result(<<"DELETE">>, {ok, Res}, Req, State) ->
    Req2 = cowboy_req:set_resp_body(jiffy:encode(Res), Req),
    Req3 = cowboy_req:reply(200, Req2),
    {jiffy:encode(Res), Req3, State};
handle_result(Verb, ok, Req, State) ->
    handle_result(Verb, {ok, nocontent}, Req, State);
handle_result(<<"GET">>, {ok, Result}, Req, State) ->
    {jiffy:encode(Result), Req, State};
handle_result(<<"POST">>, {ok, nocontent}, Req, State) ->
    Req2 = cowboy_req:reply(204, Req),
    {stop, Req2, State};
handle_result(<<"POST">>, {ok, Res}, Req, State) ->
    Path = iolist_to_binary(cowboy_req:uri(Req)),
    Req2 = cowboy_req:set_resp_body(Res, Req),
    Req3 = maybe_add_location_header(Res, binary_to_list(Path), Req2),
    {stop, Req3, State};
handle_result(<<"PUT">>, {ok, nocontent}, Req, State) ->
    Req2 = cowboy_req:reply(204, Req),
    {stop, Req2, State};
handle_result(<<"PUT">>, {ok, Res}, Req, State) ->
    Req2 = cowboy_req:set_resp_body(Res, Req),
    Req3 = cowboy_req:reply(201, Req2),
    {stop, Req3, State};
handle_result(_, {error, Error, Reason}, Req, State) ->
    error_response(Error, Reason, Req, State);
handle_result(no_call, _, Req, State) ->
    error_response(not_implemented, <<>>, Req, State).


-spec parse_request_body(any()) -> {args_applied(), cowboy_req:req()} | {error, any()}.
parse_request_body(Req) ->
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    {Data} = jiffy:decode(Body),
    try
        Params = create_params_proplist(Data),
        {Params, Req2}
    catch
        Class:Reason:StackTrace ->
            ?LOG_ERROR(#{what => parse_request_body_failed, class => Class,
                         reason => Reason, stacktrace => StackTrace}),
            {error, Reason}
    end.

%% @doc Checks if the arguments are correct. Return the arguments that can be applied to the
%% execution of command.
-spec check_and_extract_args(arg_spec_list(), optarg_spec_list(), args_applied()) ->
                             map() | {error, atom(), any()}.
check_and_extract_args(ReqArgs, OptArgs, RequestArgList) ->
    try
        AllArgs = ReqArgs ++ [{N, T} || {N, T, _} <- OptArgs],
        AllArgVals = [{N, T, proplists:get_value(N, RequestArgList)} || {N, T} <- AllArgs],
        ConvArgs = [{N, convert_arg(T, V)} || {N, T, V} <- AllArgVals, V =/= undefined],
        maps:from_list(ConvArgs)
    catch
        Class:Reason:StackTrace ->
            ?LOG_ERROR(#{what => check_and_extract_args_failed, class => Class,
                         reason => Reason, stacktrace => StackTrace}),
            {error, bad_request, Reason}
    end.

-spec execute_command(mongoose_commands:args(),
                      mongoose_commands:t(),
                      mongoose_commands:caller()) ->
    correct_result() | error_result().
execute_command(ArgMap, Command, Entity) ->
    mongoose_commands:execute(Entity, mongoose_commands:name(Command), ArgMap).

-spec maybe_add_caller(admin | binary()) -> list() | list({caller, binary()}).
maybe_add_caller(admin) ->
    [];
maybe_add_caller(JID) ->
    [{caller, JID}].

-spec maybe_add_location_header(binary() | list(), list(), any())
    -> cowboy_req:req().
maybe_add_location_header(Result, ResourcePath, Req) when is_binary(Result) ->
    add_location_header(binary_to_list(Result), ResourcePath, Req);
maybe_add_location_header(Result, ResourcePath, Req) when is_list(Result) ->
    add_location_header(Result, ResourcePath, Req);
maybe_add_location_header(_, _Path, Req) ->
    cowboy_req:reply(204, #{}, Req).

add_location_header(Result, ResourcePath, Req) ->
    Path = [ResourcePath, "/", Result],
    Headers = #{<<"location">> => Path},
    cowboy_req:reply(201, Headers, Req).

-spec convert_arg(atom(), any()) -> boolean() | integer() | float() | binary() | string() | {error, bad_type}.
convert_arg(binary, Binary) when is_binary(Binary) ->
    Binary;
convert_arg(boolean, Value) when is_boolean(Value) ->
    Value;
convert_arg(integer, Binary) when is_binary(Binary) ->
    binary_to_integer(Binary);
convert_arg(integer, Integer) when is_integer(Integer) ->
    Integer;
convert_arg(float, Binary) when is_binary(Binary) ->
    binary_to_float(Binary);
convert_arg(float, Float) when is_float(Float) ->
    Float;
convert_arg([Type], List) when is_list(List) ->
    [ convert_arg(Type, Item) || Item <- List ];
convert_arg(_, _Binary) ->
    throw({error, bad_type}).

-spec create_params_proplist(list({binary(), binary()})) -> args_applied().
create_params_proplist(ArgList) ->
    lists:sort([{to_atom(Arg), Value} || {Arg, Value} <- ArgList]).

%% @doc Returns list of allowed methods.
-spec get_allowed_methods(admin | user) -> list(method()).
get_allowed_methods(Entity) ->
    Commands = mongoose_commands:list(Entity),
    [action_to_method(mongoose_commands:action(Command)) || Command <- Commands].

-spec maybe_add_bindings(mongoose_commands:t(), admin|user) -> iolist().
maybe_add_bindings(Command, Entity) ->
    Action = mongoose_commands:action(Command),
    Args = mongoose_commands:args(Command),
    BindAndBody = both_bind_and_body(Action),
    case BindAndBody of
        true ->
            Ids = mongoose_commands:identifiers(Command),
            Bindings = [El || {Key, _Value} = El <- Args, true =:= proplists:is_defined(Key, Ids)],
            add_bindings(Bindings, Entity);
        false ->
            add_bindings(Args, Entity)
    end.

maybe_add_subcategory(Command) ->
    SubCategory = mongoose_commands:subcategory(Command),
    case SubCategory of
        undefined ->
            [];
        _ ->
            ["/", SubCategory]
    end.

-spec both_bind_and_body(mongoose_commands:action()) -> boolean().
both_bind_and_body(update) ->
    true;
both_bind_and_body(create) ->
    true;
both_bind_and_body(read) ->
    false;
both_bind_and_body(delete) ->
    false.

add_bindings(Args, Entity) ->
    [add_bind(A, Entity) || A <- Args].

%% skip "caller" arg for frontend command
add_bind({caller, _}, user) ->
    "";
add_bind({ArgName, _}, _Entity) ->
    lists:flatten(["/:", atom_to_list(ArgName)]);
add_bind(Other, _) ->
    throw({error, bad_arg_spec, Other}).

-spec to_atom(binary() | atom()) -> atom().
to_atom(Bin) when is_binary(Bin) ->
    erlang:binary_to_existing_atom(Bin, utf8);
to_atom(Atom) when is_atom(Atom) ->
    Atom.

%%--------------------------------------------------------------------
%% HTTP utils
%%--------------------------------------------------------------------
%%-spec error_response(mongoose_commands:errortype(), any(), http_api_state()) ->
%%                     {stop, any(), http_api_state()}.
%%error_response(ErrorType, Req, State) ->
%%    error_response(ErrorType, <<>>, Req, State).

-spec error_response(mongoose_commands:errortype(), mongoose_commands:errorreason(), cowboy_req:req(), http_api_state()) ->
    {stop, cowboy_req:req(), http_api_state()}.
error_response(ErrorType, Reason, Req, State) ->
    BinReason = case Reason of
                    B when is_binary(B) -> B;
                    L when is_list(L) -> list_to_binary(L);
                    Other -> list_to_binary(io_lib:format("~p", [Other]))
                end,
    ?LOG_ERROR(#{what => rest_common_error,
                 error_type => ErrorType, reason => Reason, req => Req}),
    Req1 = cowboy_req:reply(error_code(ErrorType), #{}, BinReason, Req),
    {stop, Req1, State}.

%% HTTP status codes
error_code(denied) -> 403;
error_code(not_implemented) -> 501;
error_code(bad_request) -> 400;
error_code(type_error) -> 400;
error_code(not_found) -> 404;
error_code(internal) -> 500;
error_code(Other) ->
    ?WARNING_MSG("Unknown error identifier \"~p\". See mongoose_commands:errortype() for allowed values.", [Other]),
    500.

action_to_method(read) -> <<"GET">>;
action_to_method(update) -> <<"PUT">>;
action_to_method(delete) -> <<"DELETE">>;
action_to_method(create) -> <<"POST">>;
action_to_method(_) -> undefined.

method_to_action(<<"GET">>) -> read;
method_to_action(<<"POST">>) -> create;
method_to_action(<<"PUT">>) -> update;
method_to_action(<<"DELETE">>) -> delete.

%%--------------------------------------------------------------------
%% Authorization
%%--------------------------------------------------------------------

-spec get_auth_details(cowboy_req:req()) ->
    {basic, User :: binary(), Password :: binary()} | undefined.
get_auth_details(Req) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, _User, _Password} = Details ->
            Details;
        _ ->
            undefined
    end.

-spec is_known_auth_method(atom()) -> boolean().
is_known_auth_method(basic) -> true;
is_known_auth_method(_) -> false.

make_unauthorized_response(Req, State) ->
    {{false, <<"Basic realm=\"mongooseim\"">>}, Req, State}.
