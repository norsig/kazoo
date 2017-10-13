%%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2017, 2600Hz
%%% @doc
%%% Created when a call hits a fetch_handler in ecallmgr_route.
%%% A Control Queue is created by the lookup_route function in the
%%% fetch_handler. On initialization, besides adding itself as the
%%% consumer for the AMQP messages, Call Control creates an empty queue
%%% object (not to be confused with AMQP queues), sets the current
%%% application running on the switch to the empty binary, and records
%%% the timestamp of when the initialization finishes. The process then
%%% enters its loop to wait.
%%%
%%% When receiving an AMQP message, after decoding the JSON into a proplist,
%%% we check if the application is "queue" or not; if it is "queue", we
%%% extract the default headers out, iterate through the Commands portion,
%%% and append the default headers to the application-specific portions, and
%%% insert these commands into the CmdQ. We then check whether the old CmdQ is
%%% empty AND the new CmdQ is not, and that the current App is the empty
%%% binary. If so, we dequeue the next command, execute it, and loop; otherwise
%%% we loop with the CmdQ.
%%% If just a single application is sent in the message, we check the CmdQ's
%%% size and the current App's status; if both are empty, we fire the command
%%% immediately; otherwise we add the command to the CmdQ and loop.
%%%
%%% When receiving an {execute_complete, CALLID, EvtName} tuple from
%%% the corresponding ecallmgr_call_events process tracking the call,
%%% we convert the CurrApp name from Kazoo parlance to FS, matching
%%% it against what application name we got from FS via the events
%%% process. If CurrApp is empty, we just loop since the completed
%%% execution probably wasn't related to our stuff (perhaps FS internal);
%%% if the converted Kazoo name matches the passed FS name, we know
%%% the CurrApp cmd has finished and can execute the next command in the
%%% queue. If there are no commands in the queue, set CurrApp to 'undefined' and
%%% loop; otherwise take the next command, execute it, and look with it as
%%% the CurrApp. If EvtName and the converted Kazoo name don't match,
%%% something else executed that might have been related to the main
%%% application's execute (think set commands, like playback terminators);
%%% we can note the event happened, and continue looping as we were.
%%% @end
%%%
%%% @contributors
%%%   James Aimonetti <james@2600hz.org>
%%%   Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(ecallmgr_call_control).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1]).
-export([callid/1]).
-export([node/1]).
-export([hostname/1]).
-export([queue_name/1]).
-export([other_legs/1
        ,update_node/2
        ,control_procs/1
        ]).
-export([fs_nodeup/2]).
-export([fs_nodedown/2]).

%% gen_server callbacks
-export([handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ,init/1
        ,init_control/2
        ]).

-include("ecallmgr.hrl").

-define(SERVER, ?MODULE).

-define(KEEP_ALIVE, 2 * ?MILLISECONDS_IN_SECOND).

-type insert_at_options() :: 'now' | 'head' | 'tail' | 'flush'.

-record(state, {node :: atom()
               ,call_id :: ne_binary()
               ,command_q = queue:new() :: queue:queue()
               ,current_app :: api_binary()
               ,current_cmd :: api_object()
               ,start_time = os:timestamp() :: kz_now()
               ,is_call_up = 'true' :: boolean()
               ,is_node_up = 'true' :: boolean()
               ,keep_alive_ref :: api_reference()
               ,other_legs = [] :: ne_binaries()
               ,last_removed_leg :: api_binary()
               ,sanity_check_tref :: api_reference()
               ,msg_id :: api_binary()
               ,fetch_id :: api_binary()
               ,controller_q :: api_binary()
               ,controller_p :: api_pid()
               ,control_q :: api_binary()
               ,initial_ccvs :: kz_json:object()
               ,node_down_tref :: api_reference()
               ,current_cmd_uuid :: api_binary()
               }).
-type state() :: #state{}.

-define(RESPONDERS, []).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Starts the server
%%--------------------------------------------------------------------
-spec start_link(map()) -> startlink_ret().
start_link(Map) ->
    proc_lib:start_link(?MODULE, 'init_control', [self(), Map]).

-spec stop(pid()) -> 'ok'.
stop(Srv) ->
    gen_server:cast(Srv, 'stop').

-spec callid(pid()) -> ne_binary().
callid(Srv) ->
    gen_server:call(Srv, 'callid', ?MILLISECONDS_IN_SECOND).

-spec node(pid()) -> ne_binary().
node(Srv) ->
    gen_server:call(Srv, 'node', ?MILLISECONDS_IN_SECOND).

-spec hostname(pid()) -> binary().
hostname(Srv) ->
    Node = ?MODULE:node(Srv),
    case binary:split(kz_term:to_binary(Node), <<"@">>) of
       [_, Hostname] -> Hostname;
       Other -> Other
    end.

-spec queue_name(pid() | 'undefined') -> api_binary().
queue_name(Srv) when is_pid(Srv) -> gen_server:call(Srv, 'queue_name');
queue_name(_) -> 'undefined'.

-spec other_legs(pid()) -> ne_binaries().
other_legs(Srv) ->
    gen_server:call(Srv, 'other_legs', ?MILLISECONDS_IN_SECOND).

%% -spec event_execute_complete(api_pid(), ne_binary(), ne_binary()) -> 'ok'.
%% event_execute_complete('undefined', _CallId, _App) -> 'ok';
%% event_execute_complete(Srv, CallId, App) ->
%%     gen_server:cast(Srv, {'event_execute_complete', CallId, App, kz_json:new()}).

-spec update_node(atom(), ne_binary() | pids()) -> 'ok'.
update_node(Node, CallId) when is_binary(CallId) ->
    update_node(Node, gproc:lookup_pids({'p', 'l', {'call_control', CallId}}));
update_node(Node, Pids) when is_list(Pids) ->
    _ = [gen_server:cast(Srv, {'update_node', Node}) || Srv <- Pids],
    'ok'.

-spec control_procs(ne_binary()) -> pids().
control_procs(CallId) ->
    gproc:lookup_pids({'p', 'l', {'call_control', CallId}}).

-spec fs_nodeup(pid(), atom()) -> 'ok'.
fs_nodeup(Srv, Node) ->
    gen_server:cast(Srv, {'fs_nodeup', Node}).

-spec fs_nodedown(pid(), atom()) -> 'ok'.
fs_nodedown(Srv, Node) ->
    gen_server:cast(Srv, {'fs_nodedown', Node}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(list()) -> {'ok', state()}.
init(_) ->
    lager:error("HEY!!"),
    {'ok', #state{}}.

-spec init_control(pid() , map()) -> 'ok'.
init_control(Pid, #{node := Node
                   ,call_id := CallId
                   ,callback := Fun
                   ,fetch_id := FetchId
                   }=Payload) ->
    proc_lib:init_ack(Pid, {'ok', self()}),
    Name = ?CALL_CTL_NAME(CallId),
    try Fun(Payload) of
        {'ok', #{controller_q := ControllerQ
                ,controller_p := ControllerP
                ,control_q := ControlQ
                ,initial_ccvs := CCVs
                }} ->
            bind(Node, CallId),
            TRef = erlang:send_after(?SANITY_CHECK_PERIOD, self(), 'sanity_check'),
            State = #state{node=Node
                          ,call_id=CallId
                          ,command_q=queue:new()
                          ,start_time=os:timestamp()
                          ,sanity_check_tref=TRef
                          ,fetch_id=FetchId
                          ,controller_q=ControllerQ
                          ,controller_p=ControllerP
                          ,control_q=ControlQ
                          ,initial_ccvs=CCVs
                          ,is_node_up=true
                          ,is_call_up=true
                          },
            call_control_ready(State),
            register(Name, self()),
            gen_server:enter_loop(?MODULE, [], State, {'local', Name});
        _Other ->
                lager:debug("INIT_CONTROL5")
    catch
        _Ex:_Err ->
            lager:debug("BINDINGS ~p : ~p", [_Ex, _Err]),
            kz_util:log_stacktrace()
    end,
    lager:debug("INIT_CONTROL_EXIT"),
    'ok';
init_control(Pid, #{node := Node
                   ,call_id := CallId
                   ,fetch_id := FetchId
                   ,controller_q := ControllerQ
                   ,controller_p := ControllerP
                   ,control_q := ControlQ
                   ,initial_ccvs := CCVs                   
                   }) ->
    proc_lib:init_ack(Pid, {'ok', self()}),
    Name = ?CALL_CTL_NAME(CallId),
    bind(Node, CallId),
    TRef = erlang:send_after(?SANITY_CHECK_PERIOD, self(), 'sanity_check'),
    State = #state{node=Node
                  ,call_id=CallId
                  ,command_q=queue:new()
                  ,start_time=os:timestamp()
                  ,sanity_check_tref=TRef
                  ,fetch_id=FetchId
                  ,controller_q=ControllerQ
                  ,controller_p=ControllerP
                  ,control_q=ControlQ
                  ,initial_ccvs=CCVs
                  ,is_node_up=true
                  ,is_call_up=true
                  },
    call_control_ready(State),
    register(Name, self()),
    gen_server:enter_loop(?MODULE, [], State, {'local', Name}),
    lager:debug("INIT_CONTROL_EXIT"),
    'ok'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_call(any(), pid_ref(), state()) -> handle_call_ret_state(state()).
handle_call('node', _From, #state{node=Node}=State) ->
    {'reply', Node, State};
handle_call('queue_name', _From, #state{control_q=Q}=State) ->
    {'reply', Q, State};
handle_call('callid', _From, #state{call_id=CallId}=State) ->
    {'reply', CallId, State};
handle_call('other_legs', _From, #state{other_legs=Legs}=State) ->
    {'reply', Legs, State};
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(any(), state()) -> handle_cast_ret_state(state()).
%% handle_cast('init', #state{node=Node
%%                           ,call_id=CallId
%%                           }=State) ->
%% %    gproc:reg({'p', 'l', 'call_control'}),
%%     reg_for_call_related_events(CallId),
%%     bind_to_events(Node, CallId),
%%     TRef = erlang:send_after(?SANITY_CHECK_PERIOD, self(), 'sanity_check'),
%%     {'noreply', State#state{sanity_check_tref=TRef}};
handle_cast('stop', State) ->
    {'stop', 'normal', State};
handle_cast({'update_node', Node}, #state{node=OldNode}=State) ->
    lager:debug("channel has moved from ~s to ~s", [OldNode, Node]),
    {'noreply', State#state{node=Node}};
handle_cast({'dialplan', JObj}, State) ->
    {'noreply', handle_dialplan(JObj, State)};
handle_cast({'fs_nodedown', Node}, #state{node=Node
                                         ,is_node_up='true'
                                         }=State) ->
    lager:debug("lost connection to media node ~s", [Node]),
    TRef = erlang:send_after(?MAX_TIMEOUT_FOR_NODE_RESTART, self(), 'nodedown_restart_exceeded'),
    {'noreply', State#state{is_node_up='false'
                           ,node_down_tref=TRef
                           }};
handle_cast({'fs_nodeup', Node}, #state{node=Node
                                       ,call_id=CallId
                                       ,is_node_up='false'
                                       ,node_down_tref=TRef
                                       }=State) ->
    lager:debug("regained connection to media node ~s", [Node]),
    _ = (catch erlang:cancel_timer(TRef)),
    _ = timer:sleep(100 + rand:uniform(1400)),
    case freeswitch:api(Node, 'uuid_exists', CallId) of
        {'ok', <<"true">>} ->
            {'noreply', force_queue_advance(State#state{is_node_up='true'})};
        _Else ->
            {'noreply', handle_channel_destroyed(kz_json:new(), State)}
    end;
handle_cast(_, State) ->
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_info(any(), state()) -> handle_info_ret_state(state()).
handle_info({'event', CallId, JObj}, #state{call_id=CallId}=State) ->
    handle_event_info(CallId, JObj, State);
handle_info({'call_control', JObj}, State) ->
    handle_call_control(JObj, State),
    {'noreply', State};
handle_info({'usurp_control', FetchId, _JObj}, #state{fetch_id = FetchId} = State) ->
    {'noreply', State};
handle_info({'usurp_control', _FetchId, _JObj}, State) ->
    lager:debug("the call has been usurped by an external process"),
    {'stop', 'normal', State};
handle_info({'force_queue_advance', CallId}, #state{call_id=CallId}=State) ->
    {'noreply', force_queue_advance(State)};
handle_info({'force_queue_advance', _}, State) ->
    {'noreply', State};
handle_info('keep_alive_expired', State) ->
    lager:debug("no new commands received after channel destruction, our job here is done"),
    {'stop', 'normal', State};
handle_info('sanity_check', #state{call_id=CallId}=State) ->
    case ecallmgr_fs_channel:exists(CallId) of
        'true' ->
            lager:debug("listener passed sanity check, call is still up"),
            TRef = erlang:send_after(?SANITY_CHECK_PERIOD, self(), 'sanity_check'),
            {'noreply', State#state{sanity_check_tref=TRef}};
        'false' ->
            lager:debug("call uuid does not exist, executing post-hangup events and terminating"),
            {'noreply', handle_channel_destroyed(kz_json:new(), State)}
    end;
handle_info('nodedown_restart_exceeded', #state{is_node_up='false'}=State) ->
    lager:debug("we have not received a node up in time, assuming down for good for this call", []),
    {'noreply', handle_channel_destroyed(kz_json:new(), State)};
handle_info(?LOOPBACK_BOWOUT_MSG(Node, Props), #state{call_id=ResigningUUID
                                                     ,node=Node
                                                     }=State) ->
    case {props:get_value(?RESIGNING_UUID, Props)
         ,props:get_value(?ACQUIRED_UUID, Props)
         }
    of
        {ResigningUUID, ResigningUUID} ->
            lager:debug("call id after bowout remains the same"),
            {'noreply', State};
        {ResigningUUID, AcquiringUUID} ->
            lager:debug("replacing ~s with ~s", [ResigningUUID, AcquiringUUID]),
%%            {'noreply', handle_sofia_replaced(AcquiringUUID, State)};
            {'noreply', State#state{call_id=AcquiringUUID}};
        {_UUID, _AcuiringUUID} ->
            lager:debug("ignoring bowout for ~s", [_UUID]),
            {'noreply', State}
    end;
handle_info({switch_reply, _}, State) ->
    {'noreply', State};
handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%%
%% @spec handle_event(JObj, State) -> {reply, Options}
%% @end
%%--------------------------------------------------------------------
-spec handle_call_control(kz_json:object(), state()) -> gen_server:handle_event_return().
handle_call_control(JObj, _State) ->
    case kz_util:get_event_type(JObj) of
        {<<"call">>, <<"command">>} -> handle_call_command(JObj);
        {<<"conference">>, <<"command">>} -> handle_conference_command(JObj);
        {_Category, _Event} -> lager:debug_unsafe("event ~s : ~s not handled : ~s", [_Category, _Event, kz_json:encode(JObj, ['pretty'])])
    end.

-spec handle_call_command(kz_json:object()) -> 'ok'.
handle_call_command(JObj) ->
    gen_server:cast(self(), {'dialplan', JObj}).

-spec handle_conference_command(kz_json:object()) -> 'ok'.
handle_conference_command(JObj) ->
    gen_server:cast(self(), {'dialplan', JObj}).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, #state{start_time=StartTime
                         ,sanity_check_tref=SCTRef
                         ,keep_alive_ref=KATRef
                         }) ->
    catch (erlang:cancel_timer(SCTRef)),
    catch (erlang:cancel_timer(KATRef)),
    catch(kz_amqp_channel:release()),
    lager:debug("control queue was up for ~p microseconds", [timer:now_diff(os:timestamp(), StartTime)]),
    'ok'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec call_control_ready(state()) -> 'ok'.
call_control_ready(#state{call_id=CallId
                         ,controller_q=ControllerQ
                         ,controller_p=ControllerP
                         ,control_q=Q
                         ,initial_ccvs=CCVs
                         ,fetch_id=FetchId
                         ,node=Node
                         }) ->
    App = <<"kz_multiset">>,
    Arg = list_to_binary(["^^;Call-Control-Queue="
                         ,Q
                         ,";Call-Control-PID="
                         ,kz_term:to_binary(self())
                         ]),    
    Command = [{<<"call-command">>, <<"execute">>}
              ,{<<"execute-app-name">>, App}
              ,{<<"execute-app-arg">>, Arg}
              ],
    freeswitch:cast_cmd(Node, CallId, Command),
    
    Win = [{<<"Msg-ID">>, CallId}
          ,{<<"Reply-To-PID">>, ControllerP}
          ,{<<"Call-ID">>, CallId}
          ,{<<"Control-Queue">>, Q}
          ,{<<"Control-PID">>, kz_term:to_binary(self())}
          ,{<<"Custom-Channel-Vars">>, CCVs}
           | kz_api:default_headers(Q, <<"dialplan">>, <<"route_win">>, ?APP_NAME, ?APP_VERSION)
          ],
    lager:debug("sending route_win to ~s", [ControllerQ]),
    kapi_route:publish_win(ControllerQ, Win),
    Usurp = [{<<"Call-ID">>, CallId}
            ,{<<"Fetch-ID">>, FetchId}
            ,{<<"Reason">>, <<"Route-Win">>}
            ,{<<"Media-Node">>, kz_term:to_binary(Node)}
             | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
            ],
    lager:debug("sending control usurp for ~s", [FetchId]),
    kapi_call:publish_usurp_control(CallId, Usurp).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_channel_destroyed(kz_json:object(), state()) -> state().
handle_channel_destroyed(_,  #state{sanity_check_tref=SCTRef
                                   ,current_app=CurrentApp
                                   ,current_cmd=CurrentCmd
                                   ,call_id=CallId
                                   }=State) ->
    lager:debug("our channel has been destroyed, executing any post-hangup commands"),
    %% if our sanity check timer is running stop it, it will always return false
    %% now that the channel is gone
    catch (erlang:cancel_timer(SCTRef)),

    %% if the current application can not be run without a channel and we have received the
    %% channel_destory (the last event we will ever receive from freeswitch for this call)
    %% then create an error and force advance. This will happen with dialplan actions that
    %% have not been executed on freeswitch but were already queued (for example in xferext).
    %% Commonly events like masquerade, noop, etc
    _ = case CurrentApp =:= 'undefined'
%            orelse is_post_hangup_command(CurrentApp)
        of
            'true' -> 'ok';
            'false' ->
                maybe_send_error_resp(CallId, CurrentCmd),
                self() ! {'force_queue_advance', CallId}
        end,
    State#state{keep_alive_ref=get_keep_alive_ref(State#state{is_call_up='false'})
               ,is_call_up='false'
               ,is_node_up='true'
               }.

-spec force_queue_advance(state()) -> state().
force_queue_advance(#state{call_id=CallId
                          ,current_app=CurrApp
                          ,command_q=CmdQ
                          ,is_node_up=INU
                          ,is_call_up=CallUp
                          }=State) ->
    lager:debug("received control queue unconditional advance, skipping wait for command completion of '~s'"
               ,[CurrApp]),
    case INU
        andalso queue:out(CmdQ)
    of
        'false' ->
            %% if the node is down, don't inject the next FS event
            lager:debug("not continuing until the media node becomes avaliable"),
            State#state{current_app='undefined', current_cmd_uuid='undefined'};
        {'empty', _} ->
            lager:debug("no call commands remain queued, hibernating"),
            State#state{current_app='undefined', current_cmd_uuid='undefined'};
        {{'value', Cmd}, CmdQ1} ->
            AppName = kz_json:get_value(<<"Application-Name">>, Cmd),
            MsgId = kz_json:get_value(<<"Msg-ID">>, Cmd),
            case CallUp
                andalso execute_control_request(Cmd, State)
            of
                    'false' ->
                        lager:debug("command '~s' is not valid after hangup, skipping", [AppName]),
                        maybe_send_error_resp(CallId, Cmd),
                        self() ! {'force_queue_advance', CallId},
                        State#state{command_q=CmdQ1
                                   ,current_app=AppName
                                   ,current_cmd=Cmd
                                   ,keep_alive_ref=get_keep_alive_ref(State)
                                   ,msg_id=MsgId
                                   };
                'ok' ->
                        State#state{command_q=CmdQ1
                                   ,current_app=AppName
                                   ,current_cmd=Cmd
                                   ,keep_alive_ref=get_keep_alive_ref(State)
                                   ,msg_id=MsgId
                                   };
                {'ok', EventUUID} ->
                        State#state{command_q=CmdQ1
                                   ,current_app=AppName
                                   ,current_cmd=Cmd
                                   ,current_cmd_uuid = EventUUID
                                   ,keep_alive_ref=get_keep_alive_ref(State)
                                   ,msg_id=MsgId
                                   }
                end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_execute_complete(api_binary(), api_binary(), kz_json:object(), state()) -> state().
handle_execute_complete('undefined', _, _JObj, State) ->
    lager:debug_unsafe("call control received undefined : ~s", [kz_json:encode(_JObj, ['pretty'])]),
    State;
handle_execute_complete(_, 'undefined', _JObj, State) ->
    lager:debug_unsafe("call control received undefined : ~s", [kz_json:encode(_JObj, ['pretty'])]),    
    State;
handle_execute_complete(_AppName, _EventUUID, _JObj, #state{current_cmd_uuid='undefined'}=State) ->
    State;
handle_execute_complete(<<"noop">>, EventUUID, JObj, #state{msg_id=CurrMsgId, current_cmd_uuid=EventUUID}=State) ->
    NoopId = kz_json:get_value(<<"Application-Response">>, JObj),
    case NoopId =:= CurrMsgId of
        'false' ->
            lager:debug("received noop execute complete with incorrect id ~s (expecting ~s)"
                       ,[NoopId, CurrMsgId]
                       ),
            State;
        'true' ->
            lager:debug("noop execution complete for ~s, advancing control queue", [NoopId]),
            forward_queue(State)
    end;
handle_execute_complete(<<"playback">> = AppName, EventUUID, JObj, #state{current_app=AppName
                                                              ,current_cmd_uuid=EventUUID
                                                              ,command_q=CmdQ}=State) ->
    lager:debug("playback finished, checking for group-id/DTMF termination"),
    S = case kz_json:get_value(<<"DTMF-Digit">>, JObj) of
            'undefined' ->
                lager:debug("command finished playing, advancing control queue"),
                State;
            _DTMF ->
                GroupId = kz_json:get_value(<<"Group-ID">>, JObj),
                lager:debug("DTMF ~s terminated playback, flushing all with group id ~s"
                           ,[_DTMF, GroupId]),
                State#state{command_q=flush_group_id(CmdQ, GroupId, AppName)}
        end,
    forward_queue(S);
handle_execute_complete(AppName, EventUUID, _, #state{current_app=AppName, current_cmd_uuid=EventUUID}=State) ->
    lager:debug("~s execute complete, advancing control queue", [AppName]),
    forward_queue(State);
handle_execute_complete(AppName, EventUUID, JObj, #state{current_app=CurrApp, current_cmd_uuid=EventUUID}=State) ->
    RawAppName = kz_json:get_value(<<"Raw-Application-Name">>, JObj, AppName),
    CurrentAppName = ecallmgr_util:convert_kazoo_app_name(CurrApp),
    case lists:member(RawAppName, CurrentAppName) of
        'true' -> handle_execute_complete(CurrApp, EventUUID, JObj, State);
        'false' -> State
    end;
handle_execute_complete(AppName, EventUUID, JObj, #state{current_app=CurrApp, current_cmd_uuid=CurEventUUID}=State) ->
    lager:debug_unsafe("call control received ~s with ~s but our state is ~s , ~s : ~s", [AppName, EventUUID, CurrApp, CurEventUUID, kz_json:encode(JObj, ['pretty'])]),
    State.
    
-spec flush_group_id(queue:queue(), api_binary(), ne_binary()) -> queue:queue().
flush_group_id(CmdQ, 'undefined', _) -> CmdQ;
flush_group_id(CmdQ, GroupId, AppName) ->
    Filter = kz_json:from_list([{<<"Application-Name">>, AppName}
                               ,{<<"Fields">>, kz_json:from_list([{<<"Group-ID">>, GroupId}])}
                               ]),
    maybe_filter_queue([Filter], CmdQ).

-spec forward_queue(state()) -> state().
forward_queue(#state{call_id = CallId
                     ,is_node_up = INU
                     ,is_call_up = CallUp
                     ,command_q = CmdQ
                    }=State) ->
    case INU
             andalso queue:out(CmdQ)
        of
        'false' ->
            %% if the node is down, don't inject the next FS event
            lager:debug("not continuing until the media node becomes avaliable"),
            State#state{current_app='undefined', current_cmd_uuid='undefined', msg_id='undefined'};
        {'empty', _} ->
            lager:debug("no call commands remain queued, hibernating"),
            State#state{current_app='undefined', current_cmd_uuid='undefined', msg_id='undefined'};
        {{'value', Cmd}, CmdQ1} ->
            AppName = kz_json:get_value(<<"Application-Name">>, Cmd),
            MsgId = kz_json:get_value(<<"Msg-ID">>, Cmd, <<>>),
            case CallUp
                     andalso execute_control_request(Cmd, State)
                of
                'false' ->
                    lager:debug("command '~s' is not valid after hangup, skipping", [AppName]),
                    maybe_send_error_resp(CallId, Cmd),
                    self() ! {'force_queue_advance', CallId},
                    State#state{command_q = CmdQ1
                                ,current_app = AppName
                                ,current_cmd = Cmd
                                ,msg_id = MsgId
                               };
                'ok' ->
                    State#state{command_q = CmdQ1
                                ,current_app = AppName
                                ,current_cmd = Cmd
                                ,msg_id = MsgId
                               };
                {'ok', EventUUID} ->
                    MsgId = kz_json:get_value(<<"Msg-ID">>, Cmd, <<>>),
                    State#state{command_q = CmdQ1
                                ,current_app = AppName
                                ,current_cmd_uuid = EventUUID
                                ,current_cmd = Cmd
                                ,msg_id = MsgId
                               }
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_sofia_replaced(ne_binary(), state()) -> state().
handle_sofia_replaced(<<_/binary>> = CallId, #state{call_id=CallId}=State) ->
    State;
handle_sofia_replaced(<<_/binary>> = ReplacedBy, State)->
    lager:debug("CHANNEL REPLACED"),
    State#state{call_id = ReplacedBy}.
%% handle_sofia_replaced(<<_/binary>> = ReplacedBy, #state{call_id=CallId
%%                                                        ,node=Node
%%                                                        ,other_legs=Legs
%%                                                        ,command_q=CommandQ
%%                                                        }=State) ->
%%     lager:info("updating callid from ~s to ~s", [CallId, ReplacedBy]),
%%     unbind_from_events(Node, CallId),
%%     unreg_for_call_related_events(CallId),
%%     gen_server:rm_binding(self(), 'call', [{'callid', CallId}]),
%% 
%%     kz_util:put_callid(ReplacedBy),
%%     bind_to_events(Node, ReplacedBy),
%%     reg_for_call_related_events(ReplacedBy),
%%     gen_server:add_binding(self(), 'call', [{'callid', ReplacedBy}]),
%% 
%%     lager:info("...call id updated, continuing post-transfer"),
%%     Commands = [kz_json:set_value(<<"Call-ID">>, ReplacedBy, JObj)
%%                 || JObj <- queue:to_list(CommandQ)
%%                ],
%%     State#state{call_id=ReplacedBy
%%                ,other_legs=lists:delete(ReplacedBy, Legs)
%%                ,command_q=queue:from_list(Commands)
%%                }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
%% -spec handle_channel_create(kz_proplist(), state()) -> state().
%% handle_channel_create(JObj, #state{call_id=CallId}=State) ->
%%     LegId = kz_call_event:call_id(JObj),
%%     case kz_call_event:other_leg_call_id(JObj) of
%%         'undefined' -> State;
%%         CallId -> add_leg(JObj, LegId, State);
%%         OtherLeg -> maybe_add_cleg(JObj, OtherLeg, LegId, State)
%%     end.
%% 
%% -spec add_leg(kz_proplist(), ne_binary(), state()) -> state().
%% add_leg(_JObj, LegId, #state{other_legs=Legs}=State) ->
%%     case lists:member(LegId, Legs) of
%%         'true' -> State;
%%         'false' ->
%%             lager:debug("added leg ~s to call", [LegId]),
%%             State#state{other_legs=[LegId|Legs]}
%%     end.
%% 
%% -spec maybe_add_cleg(kz_proplist(), api_binary(), api_binary(), state()) -> state().
%% maybe_add_cleg(JObj, OtherLeg, LegId, #state{other_legs=Legs}=State) ->
%%     case lists:member(OtherLeg, Legs) of
%%         'true' -> add_cleg(JObj, OtherLeg, LegId, State);
%%         'false' -> State
%%     end.
%% 
%% -spec add_cleg(kz_proplist(), api_binary(), api_binary(), state()) -> state().
%% add_cleg(_JObj, _OtherLeg, 'undefined', State) -> State;
%% add_cleg(_JObj, _OtherLeg, LegId, #state{other_legs=Legs}=State) ->
%%     case lists:member(LegId, Legs) of
%%         'true' -> State;
%%         'false' ->
%%             lager:debug("added cleg ~s to call", [LegId]),
%%             State#state{other_legs=[LegId|Legs]}
%%     end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
%% -spec handle_channel_destroy(kz_proplist(), state()) -> state().
%% handle_channel_destroy(JObj, #state{call_id=CallId}=State) ->
%%     case kz_call_event:other_leg_call_id(JObj) =:= CallId of
%%         'true' -> remove_leg(JObj, State);
%%         'false' -> State
%%     end.
%% 
%% -spec remove_leg(kz_proplist(), state()) -> state().
%% remove_leg(JObj, #state{other_legs=Legs
%%                        }=State) ->
%%     LegId = kz_call_event:call_id(JObj),
%%     case lists:member(LegId, Legs) of
%%         'false' -> State;
%%         'true' ->
%%             lager:debug("removed leg ~s from call", [LegId]),
%%             State#state{other_legs=lists:delete(LegId, Legs)
%%                        ,last_removed_leg=LegId
%%                        }
%%     end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_dialplan(kz_json:object(), state()) -> state().
handle_dialplan(JObj, #state{call_id=CallId
                            ,is_node_up=INU
                            ,is_call_up=CallUp
                            ,command_q=CmdQ
                            ,current_app=CurrApp
                            }=State) ->
    NewCmdQ = try
                  insert_command(State, kz_term:to_atom(kz_json:get_value(<<"Insert-At">>, JObj, 'tail')), JObj)
              catch _T:_R ->
                      lager:debug("failed to insert command into control queue: ~p:~p", [_T, _R]),
                      CmdQ
              end,
    case INU
        andalso (not queue:is_empty(NewCmdQ))
        andalso CurrApp =:= 'undefined'
    of
        'true' ->
            {{'value', Cmd}, NewCmdQ1} = queue:out(NewCmdQ),
            AppName = kz_json:get_value(<<"Application-Name">>, Cmd),
            MsgId = kz_json:get_value(<<"Msg-ID">>, Cmd),
            case CallUp
                andalso execute_control_request(Cmd, State)
            of
                    'false' ->
                        lager:debug("command '~s' is not valid after hangup, ignoring", [AppName]),
                        maybe_send_error_resp(CallId, Cmd),
                        self() ! {'force_queue_advance', CallId},
                        State#state{command_q=NewCmdQ1
                                   ,current_app=AppName
                                   ,current_cmd=Cmd
                                   ,keep_alive_ref=get_keep_alive_ref(State)
                                   ,msg_id=MsgId
                                   };
                 {'error', Error} ->
                        lager:debug("command '~s' returned an error ~p", [AppName, Error]),
                        maybe_send_error_resp(AppName, CallId, Cmd, Error),
                        self() ! {'force_queue_advance', CallId},
                        State#state{command_q=NewCmdQ1
                                   ,current_app=AppName
                                   ,current_cmd=Cmd
                                   ,keep_alive_ref=get_keep_alive_ref(State)
                                   ,msg_id=MsgId
                                   };
                'ok' ->
                        self() ! {'force_queue_advance', CallId},
                        State#state{command_q=NewCmdQ1
                                   ,current_app=AppName
                                   ,current_cmd=Cmd
                                   ,keep_alive_ref=get_keep_alive_ref(State)
                                   ,msg_id=MsgId
                                   };
                {'ok', EventUUID} ->
                        State#state{command_q=NewCmdQ1
                                   ,current_app=AppName
                                   ,current_cmd_uuid = EventUUID
                                   ,current_cmd=Cmd
                                   ,keep_alive_ref=get_keep_alive_ref(State)
                                   ,msg_id=MsgId
                                   }
                        
                end;
        'false' ->
            State#state{command_q=NewCmdQ
                       ,keep_alive_ref=get_keep_alive_ref(State)
                       }
    end.

%% execute all commands in JObj immediately, irregardless of what is running (if anything).
-spec insert_command(state(), insert_at_options(), kz_json:object()) -> queue:queue().
insert_command(#state{node=Node
                     ,call_id=CallId
                     ,command_q=CommandQ
                     ,is_node_up=IsNodeUp
                     }=State, 'now', JObj) ->
    AName = kz_json:get_value(<<"Application-Name">>, JObj),
    case IsNodeUp
        andalso AName
    of
        'false' ->
            lager:debug("node ~s is not available", [Node]),
            lager:debug("sending execution error for command ~s", [AName]),
            {Mega,Sec,Micro} = os:timestamp(),
            Props = [{<<"Event-Name">>, <<"CHANNEL_EXECUTE_ERROR">>}
                    ,{<<"Event-Date-Timestamp">>, ((Mega * 1000000 + Sec) * 1000000 + Micro)}
                    ,{<<"Call-ID">>, CallId}
                    ,{<<"Channel-Call-State">>, <<"ERROR">>}
                    ,{<<"Custom-Channel-Vars">>, JObj}
                    ,{<<"Msg-ID">>, kz_json:get_value(<<"Msg-ID">>, JObj)}
                    ,{<<"Request">>, JObj}
                     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                    ],
            kapi_call:publish_event(Props),
            CommandQ;
        <<"queue">> ->
            'true' = kapi_dialplan:queue_v(JObj),
            Commands = kz_json:get_list_value(<<"Commands">>, JObj, []),
            DefJObj = kz_json:from_list(kz_api:extract_defaults(JObj)),
            _ = execute_queue_commands(Commands, DefJObj, State),
            CommandQ;
        <<"noop">> ->
            execute_control_request(JObj, State),
            maybe_filter_queue(kz_json:get_value(<<"Filter-Applications">>, JObj), CommandQ);
        _ ->
            lager:debug("recv and executing ~s now!", [AName]),
            execute_control_request(JObj, State),
            CommandQ
    end;
insert_command(#state{node=Node, call_id=CallId}, 'flush', JObj) ->
    lager:debug("received control queue flush command, clearing all waiting commands"),
    freeswitch:api(Node, 'uuid_break', <<CallId/binary, " all">>),
    self() ! {'force_queue_advance', CallId},
    insert_command_into_queue(queue:new(), 'tail', JObj);
insert_command(#state{command_q=CommandQ}, 'head', JObj) ->
    insert_command_into_queue(CommandQ, 'head', JObj);
insert_command(#state{command_q=CommandQ}, 'tail', JObj) ->
    insert_command_into_queue(CommandQ, 'tail', JObj);
insert_command(Q, Pos, _) ->
    lager:debug("received command for an unknown queue position: ~p", [Pos]),
    Q.

execute_queue_commands([], _, _) -> 'ok';
execute_queue_commands([Command|Commands], DefJObj, State) ->
    case kz_json:is_empty(Command)
        orelse 'undefined' =:=  kz_json:get_ne_binary_value(<<"Application-Name">>, Command)
    of
        'true' -> execute_queue_commands(Commands, DefJObj, State);
        'false' ->
            JObj = kz_json:merge_jobjs(Command, DefJObj),
            'true' = kapi_dialplan:v(JObj),
            _Ugly = insert_command(State, 'now', JObj),
            execute_queue_commands(Commands, DefJObj, State)
    end.

-spec insert_command_into_queue(queue:queue(), 'tail' | 'head', kz_json:object()) -> queue:queue().
insert_command_into_queue(Q, Position, JObj) ->
    InsertFun = queue_insert_fun(Position),
    case kz_json:get_value(<<"Application-Name">>, JObj) of
        <<"queue">> -> %% list of commands that need to be added
            insert_queue_command_into_queue(InsertFun, Q, JObj);
        _Else -> InsertFun(JObj, Q)
    end.

-spec insert_queue_command_into_queue(function(), queue:queue(), kz_json:object()) -> queue:queue().
insert_queue_command_into_queue(InsertFun, Q, JObj) ->
    'true' = kapi_dialplan:queue_v(JObj),
    DefJObj = kz_json:from_list(kz_api:extract_defaults(JObj)),
    lists:foldr(fun(CmdJObj, TmpQ) ->
                        AppCmd = kz_json:merge_jobjs(CmdJObj, DefJObj),
                        InsertFun(AppCmd, TmpQ)
                end, Q, kz_json:get_value(<<"Commands">>, JObj)).

-spec queue_insert_fun('tail' | 'head') -> function().
queue_insert_fun('tail') ->
    fun(JObj, Q) ->
            'true' = kapi_dialplan:v(JObj),
            case kz_json:get_ne_value(<<"Application-Name">>, JObj) of
                'undefined' -> Q;
                <<"noop">> = AppName ->
                    MsgId = kz_json:get_value(<<"Msg-ID">>, JObj),
                    lager:debug("inserting at the tail of the control queue call command ~s(~s)", [AppName, MsgId]),
                    queue:in(JObj, Q);
                AppName ->
                    lager:debug("inserting at the tail of the control queue call command ~s", [AppName]),
                    queue:in(JObj, Q)
            end
    end;
queue_insert_fun('head') ->
    fun(JObj, Q) ->
            'true' = kapi_dialplan:v(JObj),
            case kz_json:get_ne_value(<<"Application-Name">>, JObj) of
                'undefined' -> Q;
                <<"noop">> = AppName ->
                    MsgId = kz_json:get_value(<<"Msg-ID">>, JObj),
                    lager:debug("inserting at the head of the control queue call command ~s(~s)", [AppName, MsgId]),
                    queue:in_r(JObj, Q);
                AppName ->
                    lager:debug("inserting at the head of the control queue call command ~s", [AppName]),
                    queue:in_r(JObj, Q)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
%% See Noop documentation for Filter-Applications to get an idea of this function's purpose
-spec maybe_filter_queue('undefined' | list(), queue:queue()) -> queue:queue().
maybe_filter_queue('undefined', CommandQ) -> CommandQ;
maybe_filter_queue([], CommandQ) -> CommandQ;
maybe_filter_queue([AppName|T]=Apps, CommandQ) when is_binary(AppName) ->
    case queue:out(CommandQ) of
        {'empty', _} -> CommandQ;
        {{'value', NextJObj}, CommandQ1} ->
            case kz_json:get_value(<<"Application-Name">>, NextJObj) =:= AppName of
                'false' -> maybe_filter_queue(T, CommandQ);
                'true' ->
                    lager:debug("app ~s matched next command, popping off", [AppName]),
                    maybe_filter_queue(Apps, CommandQ1)
            end
    end;
maybe_filter_queue([AppJObj|T]=Apps, CommandQ) ->
    case queue:out(CommandQ) of
        {'empty', _} -> CommandQ;
        {{'value', NextJObj}, CommandQ1} ->
            case (AppName = kz_json:get_value(<<"Application-Name">>, NextJObj)) =:=
                kz_json:get_value(<<"Application-Name">>, AppJObj) of
                'false' -> maybe_filter_queue(T, CommandQ);
                'true' ->
                    lager:debug("app ~s matched next command, checking fields", [AppName]),
                    Fields = kz_json:get_value(<<"Fields">>, AppJObj),
                    lager:debug("fields: ~p", [Fields]),
                    case lists:all(fun({AppField, AppValue}) ->
                                           kz_json:get_value(AppField, NextJObj) =:= AppValue
                                   end, kz_json:to_proplist(Fields))
                    of
                        'false' -> maybe_filter_queue(T, CommandQ);
                        'true' ->
                            lager:debug("all fields matched next command, popping it off"),
                            maybe_filter_queue(Apps, CommandQ1) % same app and all fields matched
                    end
            end
    end.

%% -spec is_post_hangup_command(ne_binary()) -> boolean().
%% is_post_hangup_command(AppName) ->
%%     lists:member(AppName, ?POST_HANGUP_COMMANDS).

-spec get_module(ne_binary(), ne_binary()) -> atom().
get_module(Category, Name) ->
    ModuleName = <<"ecallmgr_", Category/binary, "_", Name/binary>>,
    try kz_term:to_atom(ModuleName)
    catch
        'error':'badarg' ->
            kz_term:to_atom(ModuleName, 'true')
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec execute_control_request(kz_json:object(), state()) -> 'ok'.
execute_control_request(Cmd, #state{node=Node
                                   ,call_id=CallId
                                   ,other_legs=OtherLegs
                                   }) ->
    kz_util:put_callid(CallId),
    Srv = self(),
%%    Insert = kz_json:get_atom_value(<<"Insert-At">>, Cmd, 'tail'),

    lager:debug("executing call command '~s' ~s"
               ,[kz_json:get_value(<<"Application-Name">>, Cmd)
                ,kz_json:get_value(<<"Msg-ID">>, Cmd, <<>>)
                ]),
    Mod = get_module(kz_json:get_value(<<"Event-Category">>, Cmd, <<>>)
                    ,kz_json:get_value(<<"Event-Name">>, Cmd, <<>>)
                    ),

    CmdLeg = kz_json:get_value(<<"Call-ID">>, Cmd),
    CallLeg = which_call_leg(CmdLeg, OtherLegs, CallId),

%%     try Mod:exec_cmd(Node, CallLeg, Cmd, self()) of
%%         {'ok', EventUUID} when Insert /= 'now' -> gen_server:cast(Srv, {'event_execute', EventUUID});
%%         {'ok', _EventUUID} -> Srv ! {'queue_advance', CallId};
%%         'ok' -> Srv ! {'queue_advance', CallId};
%%         {error, _Error} -> Srv ! {'force_queue_advance', CallId}
    try Mod:exec_cmd(Node, CallLeg, Cmd, self())
    catch
        _:{'error', 'nosession'} ->
            lager:debug("unable to execute command, no session"),
            send_error_resp(CallId, Cmd, <<"Session "
                                           ,CallId/binary
                                           ," not found for "
                                           ,(kz_json:get_value(<<"Application-Name">>, Cmd))/binary
                                         >>),
            Srv ! {'force_queue_advance', CallId},
            'ok';
        'error':{'badmatch', {'error', 'nosession'}} ->
            lager:debug("unable to execute command, no session"),
            send_error_resp(CallId, Cmd, <<"Session "
                                           ,CallId/binary
                                           ," not found for "
                                           ,(kz_json:get_value(<<"Application-Name">>, Cmd))/binary
                                         >>),
            Srv ! {'force_queue_advance', CallId},
            'ok';
        'error':{'badmatch', {'error', ErrMsg}} ->
            ST = erlang:get_stacktrace(),
            lager:debug("invalid command ~s: ~p", [kz_json:get_value(<<"Application-Name">>, Cmd), ErrMsg]),
            kz_util:log_stacktrace(ST),
            maybe_send_error_resp(CallId, Cmd),
            Srv ! {'force_queue_advance', CallId},
            'ok';
        'throw':{'msg', ErrMsg} ->
            lager:debug("error while executing command ~s: ~s", [kz_json:get_value(<<"Application-Name">>, Cmd), ErrMsg]),
            send_error_resp(CallId, Cmd),
            Srv ! {'force_queue_advance', CallId},
            'ok';
        'throw':Msg ->
            lager:debug("failed to execute ~s: ~s", [kz_json:get_value(<<"Application-Name">>, Cmd), Msg]),
            lager:debug("only handling call id(s): ~p", [[CallId | OtherLegs]]),

            send_error_resp(CallId, Cmd, Msg),
            Srv ! {'force_queue_advance', CallId},
            'ok';
        _A:_B ->
            ST = erlang:get_stacktrace(),
            lager:debug("exception (~s) while executing ~s: ~p", [_A, kz_json:get_value(<<"Application-Name">>, Cmd), _B]),
            kz_util:log_stacktrace(ST),
            send_error_resp(CallId, Cmd),
            Srv ! {'force_queue_advance', CallId},
            'ok'
    end.

-spec which_call_leg(ne_binary(), ne_binaries(), ne_binary()) -> ne_binary().
which_call_leg(CmdLeg, OtherLegs, CallId) ->
    case lists:member(CmdLeg, OtherLegs) of
        'true' ->
            lager:debug("executing against ~s instead", [CmdLeg]),
            CmdLeg;
        'false' -> CallId
    end.

-spec maybe_send_error_resp(ne_binary(), kz_json:object()) -> 'ok'.
-spec maybe_send_error_resp(ne_binary(), ne_binary(), kz_json:object()) -> 'ok'.
maybe_send_error_resp(CallId, Cmd) ->
    Msg = <<"Could not execute dialplan action: "
            ,(kz_json:get_value(<<"Application-Name">>, Cmd))/binary
          >>,
    maybe_send_error_resp(CallId, Cmd, Msg).

maybe_send_error_resp(CallId, Cmd, Msg) ->
    AppName = kz_json:get_value(<<"Application-Name">>, Cmd),
    maybe_send_error_resp(AppName, CallId, Cmd, Msg).

maybe_send_error_resp(<<"hangup">>, _CallId, _Cmd, _Msg) -> 'ok';
maybe_send_error_resp(_, CallId, Cmd, Msg) ->
    send_error_resp(CallId, Cmd, Msg).

-spec send_error_resp(ne_binary(), kz_json:object()) -> 'ok'.
send_error_resp(CallId, Cmd) ->
    send_error_resp(CallId
                   ,Cmd
                   ,<<"Could not execute dialplan action: "
                      ,(kz_json:get_value(<<"Application-Name">>, Cmd))/binary
                    >>
                   ).

-spec send_error_resp(ne_binary(), kz_json:object(), ne_binary()) -> 'ok'.
-spec send_error_resp(ne_binary(), kz_json:object(), ne_binary(), api_object()) -> 'ok'.
send_error_resp(CallId, Cmd, Msg) ->
    case ecallmgr_fs_channel:fetch(CallId) of
        {'ok', Channel} -> send_error_resp(CallId, Cmd, Msg, Channel);
        {'error', 'not_found'} -> send_error_resp(CallId, Cmd, Msg, 'undefined')
    end.

send_error_resp(CallId, Cmd, Msg, _Channel) ->
%%    CCVs = error_ccvs(Channel),

    Resp = [{<<"Msg-ID">>, kz_json:get_value(<<"Msg-ID">>, Cmd)}
           ,{<<"Error-Message">>, Msg}
           ,{<<"Request">>, Cmd}
           ,{<<"Call-ID">>, CallId}
%%           ,{<<"Custom-Channel-Vars">>, CCVs}
            | kz_api:default_headers(<<>>, <<"error">>, <<"dialplan">>, ?APP_NAME, ?APP_VERSION)
           ],
    lager:debug("sending execution error: ~p", [Resp]),
    kapi_dialplan:publish_error(CallId, Resp).

%% -spec error_ccvs(api_object()) -> api_object().
%% error_ccvs('undefined') -> 'undefined';
%% error_ccvs(Channel) ->
%%     kz_json:from_list(ecallmgr_fs_channel:channel_ccvs(Channel)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec get_keep_alive_ref(state()) -> api_reference().
get_keep_alive_ref(#state{is_call_up='true'}) -> 'undefined';
get_keep_alive_ref(#state{keep_alive_ref='undefined'
                         ,is_call_up='false'
                         }) ->
    lager:debug("started post hangup keep alive timer for ~bms", [?KEEP_ALIVE]),
    erlang:send_after(?KEEP_ALIVE, self(), 'keep_alive_expired');
get_keep_alive_ref(#state{keep_alive_ref=TRef
                         ,is_call_up='false'
                         }) ->
    _ = case erlang:cancel_timer(TRef) of
            'false' -> 'ok';
            _ -> %% flush the receive buffer of expiration messages
                receive 'keep_alive_expired' -> 'ok'
                after 0 -> 'ok' end
        end,
    lager:debug("reset post hangup keep alive timer"),
    erlang:send_after(?KEEP_ALIVE, self(), 'keep_alive_expired').

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec bind(atom(), ne_binary()) -> 'true'.
bind(Node, CallId) ->
    lager:debug("binding to call ~s events on node ~s", [CallId, Node]),
    'true' = gproc:reg({'p', 'l', {'call_event', Node, CallId}}),
    'true' = gproc:reg({'p', 'l', ?LOOPBACK_BOWOUT_REG(CallId)}),
     true.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
%% -spec unbind_from_events(atom(), ne_binary()) -> 'true'.
%% unbind_from_events(Node, CallId) ->
%%     lager:debug("unbinding from call ~s events on node ~s", [CallId, Node]),
%%     _ = (catch gproc:unreg({'p', 'l', {'call_event', Node, CallId}})),
%% %%     _ = (catch gproc:unreg({'p', 'l', {'event', Node, <<"CHANNEL_CREATE">>}})),
%% %%     _ = (catch gproc:unreg({'p', 'l', {'event', Node, <<"CHANNEL_DESTROY">>}})),
%%     'true'.

%% -spec reg_for_call_related_events(ne_binary()) -> 'ok'.
%% reg_for_call_related_events(CallId) ->
%% %%    gproc:reg({'p', 'l', {'call_control', CallId}}),
%%     gproc:reg({'p', 'l', ?LOOPBACK_BOWOUT_REG(CallId)}).

%% -spec unreg_for_call_related_events(ne_binary()) -> 'ok'.
%% unreg_for_call_related_events(CallId) ->
%% %    (catch gproc:unreg({'p', 'l', {'call_control', CallId}})),
%%     (catch gproc:unreg({'p', 'l', ?LOOPBACK_BOWOUT_REG(CallId)})),
%%     'ok'.

-spec handle_replaced(kz_proplist(), state()) ->
                             {'noreply', state()}.
handle_replaced(JObj, #state{fetch_id=FetchId
                             ,node=_Node
                             ,call_id=_CallId
                             }=State) ->
    case kz_call_event:custom_channel_var(JObj, <<"Fetch-ID">>) of
        FetchId ->
            ReplacedBy = kz_json:get_value(<<"Replaced-By">>, JObj),
            case ecallmgr_fs_channel:fetch(ReplacedBy) of
                {'ok', _Channel} ->
%%                     OtherLeg = kz_json:get_value(<<"other_leg">>, Channel),
%%                     OtherUUID = props:get_value(<<"Other-Leg-Unique-ID">>, Props),
%%                     CDR = kz_json:get_value(<<"interaction_id">>, Channel),
%%                     kz_cache:store_local(?ECALLMGR_INTERACTION_CACHE, CallId, CDR),
%%                     ecallmgr_fs_command:set(Node, OtherUUID, [{<<?CALL_INTERACTION_ID>>, CDR}]),
%%                     ecallmgr_fs_command:set(Node, OtherLeg, [{<<?CALL_INTERACTION_ID>>, CDR}]),
                    {'noreply', handle_sofia_replaced(ReplacedBy, State)};
                _Else ->
                    lager:debug("channel replaced was not handled : ~p", [_Else]),
                    {'noreply', State}
            end;
        _Else ->
            lager:info("sofia replaced on our channel but different fetch id~n"),
            {'noreply', State}
    end.

-spec handle_transferee(kz_proplist(), state()) ->
                               {'noreply', state()}.
handle_transferee(JObj, #state{fetch_id=FetchId
                               ,node=_Node
                               ,call_id=CallId
                               }=State) ->
    case kz_call_event:custom_channel_var(JObj, <<"Fetch-ID">>) of
        FetchId ->
            lager:info("we (~s) have been transferred, terminate immediately", [CallId]),
            {'stop', 'normal', State};
        _Else ->
            lager:info("we were a different instance of this transferred call"),
            {'noreply', State}
    end.

-spec handle_transferor(kz_proplist(), state()) ->
                               {'noreply', state()}.
handle_transferor(_Props, #state{fetch_id=_FetchId
                                ,node=_Node
                                ,call_id=_CallId
                                }=State) ->
    {'noreply', State}.

-spec handle_intercepted(atom(), ne_binary(), kz_proplist()) -> 'ok'.
handle_intercepted(_Node, _CallId, _Props) ->
%%     _ = case {props:get_value(<<"Core-UUID">>, Props)
%%              ,props:get_value(?GET_CUSTOM_HEADER(<<"Core-UUID">>), Props)
%%              }
%%         of
%%             {A, A} -> 'ok';
%%             {_, 'undefined'} ->
%%                 UUID = props:get_value(<<"intercepted_by">>, Props),
%%                 case ecallmgr_fs_channel:fetch(UUID) of
%%                     {'ok', Channel} ->
%%                         CDR = kz_json:get_value(<<"interaction_id">>, Channel),
%%                         kz_cache:store_local(?ECALLMGR_INTERACTION_CACHE, CallId, CDR),
%%                         ecallmgr_fs_command:set(Node, UUID, [{<<?CALL_INTERACTION_ID>>, CDR}]);
%%                     _ -> 'ok'
%%                 end;
%%             _ ->
%%                 UUID = props:get_value(<<"intercepted_by">>, Props),
%%                 CDR = props:get_value(?GET_CCV(<<?CALL_INTERACTION_ID>>), Props),
%%                 ecallmgr_fs_command:set(Node, UUID, [{<<?CALL_INTERACTION_ID>>, CDR}])
%%         end,
    'ok'.

-spec handle_event_info(ne_binary(), kzd_freeswitch:data(), state()) ->
                               {'noreply', state()} |
                               {'stop', any(), state()}.
handle_event_info(CallId, JObj, #state{call_id=CallId
                                      ,node=Node
                                      }=State) ->
    Application = kz_call_event:application_name(JObj),
    case kz_call_event:event_name(JObj) of
%%         <<"kazoo::", _/binary>> ->
%%             {'noreply', handle_execute_complete(Application, JObj, State)};
        <<"CHANNEL_EXECUTE_COMPLETE">> ->
            {'noreply', handle_execute_complete(Application, kz_call_event:application_uuid(JObj), JObj, State)};
%%         <<"RECORD_STOP">> ->
%%             {'noreply', handle_execute_complete(Application, JObj, State)};
        <<"CHANNEL_DESTROY">> ->
            {'noreply', handle_channel_destroyed(JObj, State)};
        <<"CHANNEL_TRANSFEREE">> ->
            handle_transferee(JObj, State);
        <<"CHANNEL_REPLACED">> ->
            handle_replaced(JObj, State);
        <<"CHANNEL_INTERCEPTED">> ->
            'ok' = handle_intercepted(Node, CallId, JObj),
            {'noreply', State};
        <<"CHANNEL_EXECUTE">> when Application =:= <<"redirect">> ->
            gen_server:cast(self(), {'channel_redirected', JObj}),
            {'stop', 'normal', State};
        <<"CHANNEL_TRANSFEROR">> ->
            handle_transferor(JObj, State);
        _Else ->
            {'noreply', State}
    end.
