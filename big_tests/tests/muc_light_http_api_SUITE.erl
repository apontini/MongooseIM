%%==============================================================================
%% Copyright 2016 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Author: Joseph Yiasemides <joseph.yiasemides@erlang-solutions.com>
%% Description: Test HTTP Administration API for MUC Light
%%==============================================================================

-module(muc_light_http_api_SUITE).
-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("exml/include/exml.hrl").

-import(muc_light_helper, [stanza_create_room/3]).
-import(distributed_helper, [subhost_pattern/1]).
-import(domain_helper, [host_type/0, domain/0]).
-import(config_parser_helper, [mod_config/2]).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, positive},
     {group, negative}].

groups() ->
    [{positive, [parallel], success_response()},
     {negative, [parallel], negative_response()}].

success_response() ->
    [create_unique_room,
     create_identifiable_room,
     invite_to_room,
     send_message_to_room,
     delete_room_by_owner
    ].

negative_response() ->
    [delete_room_by_non_owner,
     delete_non_existent_room,
     delete_room_without_having_a_membership,
     create_non_unique_room
    ].

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    Config1 = dynamic_modules:save_modules(host_type(), Config),
    dynamic_modules:ensure_modules(host_type(), required_modules()),
    escalus:init_per_suite(Config1).

end_per_suite(Config) ->
    escalus_fresh:clean(),
    dynamic_modules:restore_modules(Config),
    escalus:end_per_suite(Config).

init_per_group(_GroupName, Config) ->
    escalus:create_users(Config, escalus:get_users([alice, bob, kate])).

end_per_group(_GroupName, Config) ->
    escalus:delete_users(Config, escalus:get_users([alice, bob, kate])).

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

required_modules() ->
    [{mod_muc_light,
      mod_config(mod_muc_light, #{rooms_in_rosters => true,
                                  backend => mongoose_helper:mnesia_or_rdbms_backend()})
     }].

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

create_unique_room(Config) ->
    escalus:fresh_story(Config, [{alice, 1}], fun(Alice) ->
        Path = path([domain()]),
        Name = <<"wonderland">>,
        Body = #{ name => Name,
                  owner => escalus_client:short_jid(Alice),
                  subject => <<"Lewis Carol">>
                },
        {{<<"201">>, _}, _} = rest_helper:post(admin, Path, Body),
        [Item] = get_disco_rooms(Alice),
        MUCLightDomain = muc_light_domain(),
        true = is_room_name(Name, Item),
        true = is_room_domain(MUCLightDomain, Item)
    end).

create_identifiable_room(Config) ->
    escalus:fresh_story(Config, [{alice, 1}], fun(Alice) ->
        Path = path([domain()]),
        RandBits = base16:encode(crypto:strong_rand_bytes(5)),
        Name = <<"wonderland">>,
        RoomID = <<"just_some_id_", RandBits/binary>>,
        RoomIDescaped = escalus_utils:jid_to_lower(RoomID),
        Body = #{ id => RoomID,
                  name => Name,
                  owner => escalus_client:short_jid(Alice),
                  subject => <<"Lewis Carol">>
                },
        {{<<"201">>, _}, RoomJID} = rest_helper:putt(admin, Path, Body),
        [Item] = get_disco_rooms(Alice),
        [RoomIDescaped, MUCLightDomain] = binary:split(RoomJID, <<"@">>),
        MUCLightDomain = muc_light_domain(),
        true = is_room_name(Name, Item),
        true = is_room_domain(MUCLightDomain, Item),
        true = is_room_id(RoomIDescaped, Item)
    end).

invite_to_room(Config) ->
    Name = <<"wonderland">>,
    Path = path([muc_light_domain(), Name, "participants"]),
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}, {kate, 1}],
      fun(Alice, Bob, Kate) ->
        %% XMPP: Alice creates a room.
        Stt = stanza_create_room(undefined,
            [{<<"roomname">>, Name}], [{Kate, member}]),
        escalus:send(Alice, Stt),
        %% XMPP: Alice recieves a affiliation message to herself and
        %% an IQ result when creating the MUC Light room.
        escalus:wait_for_stanza(Alice),
        escalus:assert(is_iq_result, escalus:wait_for_stanza(Alice)),
        %% (*) HTTP: Invite Bob (change room affiliation) on Alice's behalf.
        Body = #{ sender => escalus_client:short_jid(Alice),
                  recipient => escalus_client:short_jid(Bob)
                },
        {{<<"204">>, _}, <<"">>} = rest_helper:post(admin, Path, Body),
        %% XMPP: Bob recieves his affiliation information.
        member_is_affiliated(escalus:wait_for_stanza(Bob), Bob),
        %% XMPP: Alice recieves Bob's affiliation infromation.
        member_is_affiliated(escalus:wait_for_stanza(Alice), Bob),
        %% XMPP: Alice does NOT recieve an IQ result stanza following
        %% her HTTP request to invite Bob in story point (*).
        escalus_assert:has_no_stanzas(Alice)
      end).

send_message_to_room(Config) ->
    Name = <<"wonderland">>,
    Path = path([muc_light_domain(), Name, "messages"]),
    Text = <<"Hello everyone!">>,
    escalus:fresh_story(Config,
      [{alice, 1}, {bob, 1}, {kate, 1}],
      fun(Alice, Bob, Kate) ->
        %% XMPP: Alice creates a room.
        escalus:send(Alice, stanza_create_room(undefined,
            [{<<"roomname">>, Name}], [{Bob, member}, {Kate, member}])),
        %% XMPP: Alice gets her own affiliation info
        escalus:wait_for_stanza(Alice),
        %% XMPP: And Alice gets IQ result
        CreationResult = escalus:wait_for_stanza(Alice),
        escalus:assert(is_iq_result, CreationResult),
        %% XMPP: Get Bob and Kate recieve their affiliation information.
        [ escalus:wait_for_stanza(U) || U <- [Bob, Kate] ],
        %% HTTP: Alice sends a message to the MUC room.
        Body = #{ from => escalus_client:short_jid(Alice),
                  body => Text
                },
        {{<<"204">>, _}, <<"">>} = rest_helper:post(admin, Path, Body),
        %% XMPP: Both Bob and Kate see the message.
        [ see_message_from_user(U, Alice, Text) || U <- [Bob, Kate] ]
    end).

delete_room_by_owner(Config) ->
    RoomName = <<"wonderland">>,
    escalus:fresh_story(Config,
                        [{alice, 1}, {bob, 1}, {kate, 1}],
                        fun(Alice, Bob, Kate)->
                                {{<<"204">>, <<"No Content">>}, <<"">>} =
                                    check_delete_room(Config, RoomName, RoomName,
                                                      Alice, [Bob, Kate], Alice)
                        end).

delete_room_by_non_owner(Config) ->
    RoomName = <<"wonderland">>,
    escalus:fresh_story(Config,
                        [{alice, 1}, {bob, 1}, {kate, 1}],
                        fun(Alice, Bob, Kate)->
                                {{<<"403">>, <<"Forbidden">>},
                                 <<"you can not delete this room">>} =
                                    check_delete_room(Config, RoomName, RoomName,
                                                      Alice, [Bob, Kate], Bob)
                        end).

delete_non_existent_room(Config) ->
    RoomName = <<"wonderland">>,
    escalus:fresh_story(Config,
                        [{alice, 1}, {bob, 1}, {kate, 1}],
                        fun(Alice, Bob, Kate)->
                                {{<<"404">>, _}, <<"room does not exist">>} =
                                    check_delete_room(Config, RoomName, <<"some_non_existent_room">>,
                                                      Alice, [Bob, Kate], Alice)
                        end).

delete_room_without_having_a_membership(Config) ->
    RoomName = <<"wonderland">>,
    escalus:fresh_story(Config,
                        [{alice, 1}, {bob, 1}, {kate, 1}],
                        fun(Alice, Bob, Kate)->
                                {{<<"403">>, _}, <<"given user does not occupy this room">>} =
                                    check_delete_room(Config, RoomName, RoomName,
                                                      Alice, [Bob], Kate)
                        end).


create_non_unique_room(Config) ->
    escalus:fresh_story(Config, [{alice, 1}], fun(Alice) ->
        Path = path([domain()]),
        RandBits = base16:encode(crypto:strong_rand_bytes(5)),
        Name = <<"wonderland">>,
        RoomID = <<"just_some_id_", RandBits/binary>>,
        Body = #{ id => RoomID,
                  name => Name,
                  owner => escalus_client:short_jid(Alice),
                  subject => <<"Lewis Carol">>
        },
        {{<<"201">>, _}, _RoomJID} = rest_helper:putt(admin, Path, Body),
        {{<<"403">>, _}, <<"Room already exists">>} = rest_helper:putt(admin, Path, Body),
        ok
    end).

%%--------------------------------------------------------------------
%% Ancillary (borrowed and adapted from the MUC and MUC Light suites)
%%--------------------------------------------------------------------

get_disco_rooms(User) ->
    DiscoStanza = escalus_stanza:to(escalus_stanza:iq_get(?NS_DISCO_ITEMS, []), muc_light_domain()),
    escalus:send(User, DiscoStanza),
    Stanza =  escalus:wait_for_stanza(User),
    XNamespaces = exml_query:paths(Stanza, [{element, <<"query">>}, {attr, <<"xmlns">>}]),
    true = lists:member(?NS_DISCO_ITEMS, XNamespaces),
    escalus:assert(is_stanza_from, [muc_light_domain()], Stanza),
    exml_query:paths(Stanza, [{element, <<"query">>}, {element, <<"item">>}]).

is_room_name(Name, Item) ->
    Name == exml_query:attr(Item, <<"name">>).

is_room_domain(Domain, Item) ->
    JID = exml_query:attr(Item, <<"jid">>),
    [_, Got] = binary:split(JID, <<$@>>, [global]),
    Domain == Got.

is_room_id(Id, Item) ->
    JID = exml_query:attr(Item, <<"jid">>),
    [Got, _] = binary:split(JID, <<$@>>, [global]),
    Id == Got.

see_message_from_user(User, Sender, Contents) ->
    Stanza = escalus:wait_for_stanza(User),
    #xmlel{ name = <<"message">> } = Stanza,
    SenderJID = escalus_utils:jid_to_lower(escalus_utils:get_short_jid(Sender)),
    From = exml_query:path(Stanza, [{attr, <<"from">>}]),
    {_, _} = binary:match(From, SenderJID),
    Contents = exml_query:path(Stanza, [{element, <<"body">>}, cdata]).

member_is_affiliated(Stanza, User) ->
    MemberJID = escalus_utils:jid_to_lower(escalus_utils:get_short_jid(User)),
    Data = exml_query:path(Stanza, [{element, <<"x">>}, {element, <<"user">>}, cdata]),
    MemberJID == Data.

check_delete_room(_Config, RoomNameToCreate, RoomNameToDelete, RoomOwner,
                  RoomMembers, UserToExecuteDelete) ->
    Members = [{Member, member} || Member <- RoomMembers],
    escalus:send(RoomOwner, stanza_create_room(undefined,
                                           [{<<"roomname">>, RoomNameToCreate}],
                                           Members)),
    %% XMPP RoomOwner gets affiliation and IQ result
    Affiliations = [{RoomOwner, owner} | Members],
    muc_light_helper:verify_aff_bcast([{RoomOwner, owner}], Affiliations),
    %% and now RoomOwner gets IQ result
    CreationResult = escalus:wait_for_stanza(RoomOwner),
    escalus:assert(is_iq_result, CreationResult),
    muc_light_helper:verify_aff_bcast(Members, Affiliations),
    ShortJID = escalus_client:short_jid(UserToExecuteDelete),
    Path = path([muc_light_domain(), RoomNameToDelete, ShortJID, "management"]),
    rest_helper:delete(admin, Path).


%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

path(Items) ->
    AllItems = ["muc-lights" | Items],
    iolist_to_binary([[$/, Item] || Item <- AllItems]).

muc_light_domain() ->
    muc_light_helper:muc_host().
