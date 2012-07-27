-module(socketio_transport_websocket).
-include_lib("socketio.hrl").
-behaviour(gen_server).

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, {
          session_id,
          message_handler,
          server_module,
          connection_reference,
          heartbeat_interval,
          event_manager,
          heartbeat_pings = 0,
          heartbeat_pongs = 0,
          heartbeat_drop_count = 0,
          heartbeat_drop_trigger,
          close_timeout,  %% not implemented in websockets
          sup
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Sup, SessionId, ServerModule, ConnectionReference) ->
    gen_server:start_link(?MODULE, [Sup, SessionId, ServerModule, ConnectionReference], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Sup, SessionId, ServerModule, ConnectionReference]) ->
    io:format("Initiating WS connection",[]),
    io:format("~nSup: ~p~n, SessionId: ~p~n, ServerModule: ~p~n, ConnectionRef: ~p~n",[Sup, SessionId, ServerModule, ConnectionReference]),
    % comet_heartbeat_interval is the delay between each ping to the client
    HeartbeatInterval = get_param(comet_heartbeat_interval, 5000),
    % comet_heartbeat_drop_trigger is the number of missed consequtive pongs from a client after which a heartbeat dropped event will be triggered
    HeartBeatDropTrigger = get_param(comet_heartbeat_drop_trigger, 3),
    % close_timeout is part of the original erlang socket.io implementation but is not utilised in websocket
    CloseTimeout = get_param(close_timeout, 5000),
    {ok, EventMgr} = gen_event:start_link(),
    socketio_client:send(self(), #msg{ content = SessionId }),
    gen_server:cast(self(), heartbeat),
    {ok, #state{
       session_id = SessionId,
       server_module = ServerModule,
       connection_reference = ConnectionReference,
       heartbeat_interval = {make_ref(), HeartbeatInterval},
       heartbeat_drop_trigger = HeartBeatDropTrigger,
       event_manager = EventMgr,
       sup = Sup,
       close_timeout = CloseTimeout
      }}.

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

%% Websockets
handle_call({websocket, Data, _Ws}, _From, #state{ heartbeat_pings = Pings, heartbeat_pongs = Pongs, 
                                                   heartbeat_interval = Interval, event_manager = EventManager } = State) ->
    F = fun(#heartbeat{}, _Acc) ->
            {timer, reset_interval(Interval)};            
        (M, Acc) ->
            gen_event:notify(EventManager, {message, self(), M}),
            Acc
    end,
    case lists:foldl(F, undefined, socketio_data:decode(#msg{content=Data})) of
        {timer, NewInterval} ->
            {reply, ok, State#state{heartbeat_drop_count = 0, heartbeat_pongs = Pongs + 1}};
        undefined ->
            {reply, ok, State}
    end;

handle_call({websocket, _}, _From, State) ->
    {reply, ok, State};

%% Event management
handle_call(event_manager, _From, #state{ event_manager = EventMgr } = State) ->
    {reply, EventMgr, State};

%% Sessions
handle_call(session_id, _From, #state{ session_id = SessionId } = State) ->
    {reply, SessionId, State};

%% Initial request
handle_call(req, _From, #state{ connection_reference = {websocket, Ws}} = State) ->
    {reply, Ws, State};

%% Flow control
handle_call(stop, _From, State) ->
    {stop, shutdown, State};

handle_call(Msg, _From, State) ->
    {reply, ok, State}.


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

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast({send, Message}, #state{ server_module = ServerModule,
                                     connection_reference = ConnectionReference,
                                     heartbeat_interval = Interval } = State) ->
    handle_send(ConnectionReference, Message, ServerModule),
    {noreply, State};

handle_cast(heartbeat, #state{ 
              server_module = ServerModule,
              connection_reference = ConnectionReference, heartbeat_pongs=Pongs, heartbeat_pings = Pings,
              heartbeat_interval = Interval } = State) ->
    Pings1 = Pings + 1,
    handle_send(ConnectionReference, #heartbeat{ index = Pings1 }, ServerModule),   
    {noreply, State#state { heartbeat_pings = Pings1, heartbeat_interval = reset_interval(Interval) }};

handle_cast(Msg, State) ->
    {noreply, State}.

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
handle_info({timeout, _Ref, heartbeat}, #state{ heartbeat_pings=Pings, heartbeat_pongs=Pongs,  event_manager = EventMgr,
                                                connection_reference = {websocket,{misultin_ws,Ws}}, 
                                                heartbeat_drop_count=DroppedPongs,
                                                heartbeat_drop_trigger = DropTrigger } = State) ->
  NewDroppedPongs = DroppedPongs + 1,
  case NewDroppedPongs >= DropTrigger of
    true ->
      % lets fire a heartbeat lost event for application level usage....
      % this will always be followed by a disconnect event as a result of the stop below
      DropData = [{dropped_pongs, NewDroppedPongs},{drop_trigger, DropTrigger}, {total_pongs, Pongs}, {total_pings, Pings}],
      gen_event:notify(EventMgr, {heartbeat_lost, self(), DropData}),
      {stop, shutdown, State#state{heartbeat_drop_count=NewDroppedPongs}};
    _ ->
      handle_cast(heartbeat, State#state{heartbeat_drop_count=NewDroppedPongs} )
      
  end;

handle_info(Msg, State) ->
    {noreply, State}.

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
terminate(Reason, #state{event_manager = EventMgr} = State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_send({websocket, Ws}, Message, ServerModule) ->
    apply(ServerModule, websocket_send, [Ws, socketio_data:encode(Message)]).

reset_interval({TimerRef, Time}) ->
    Res = erlang:cancel_timer(TimerRef),
    NewRef = erlang:start_timer(Time, self(), heartbeat),
    {NewRef, Time}.

check_heartbeat_status(DroppedPongs, DropTrigger) when DroppedPongs >= DropTrigger ->
  heartbeat_lost;

check_heartbeat_status(DroppedPongs, DropTrigger) ->
  ok.

get_param(Param, Default)->
    case application:get_env(web_service, Param) of
        {ok, V} ->
            V;
        _ ->
            Default
    end.
  
