%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%% Send config commands to FS
%%% @end
%%% @contributors
%%%   Edouard Swiac
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(ecallmgr_fs_config).

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/2]). 
-export([handle_config_req/4]).
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,terminate/2
         ,code_change/3
        ]).

-define(SERVER, ?MODULE).

-include("ecallmgr.hrl").

-record(state, {node = undefined :: atom()
                ,options = [] :: proplist()
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
start_link(Node) ->
    start_link(Node, []).

start_link(Node, Options) ->
    gen_server:start_link(?MODULE, [Node, Options], []).

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
init([Node, Options]) ->
    put(callid, Node),
    process_flag(trap_exit, true),
    lager:debug("starting new fs config listener for ~s", [Node]),
    case freeswitch:bind(Node, config) of
        ok ->
            lager:debug("bound to config request on ~s", [Node]),
            {ok, #state{node=Node, options=Options}};
        {error, Reason} ->
            lager:warning("failed to bind to config requests on ~s, ~p", [Node, Reason]),
            {stop, Reason};
        timeout ->
            lager:warning("failed to bind to directory requests on ~s: timeout", [Node]),
            {stop, timeout}
    end.

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
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

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
handle_cast(_Msg, State) ->
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
handle_info({fetch, configuration, <<"configuration">>, <<"name">>, Conf, ID, Data}, #state{node=Node}=State) ->
    %% TODO: move this to a supervisor somewhere....
    handle_config_req(Node, ID, Conf, Data),
    lager:debug("fetch configuration request from from ~s", [Node]),
    {noreply, State};
handle_info({_Fetch, _Section, _Something, _Key, _Value, ID, [undefined | _Data]}, #state{node=Node}=State) ->
    _ = freeswitch:fetch_reply(Node, ID, ?EMPTYRESPONSE),
    lager:debug("ignoring request ~s from ~s", [props:get_value(<<"Event-Name">>, _Data), Node]),
    {noreply, State};
handle_info(_Info, State) ->
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
terminate(_Reason, #state{node=Node}) ->
    lager:debug("fs config ~s termination: ~p", [Node, _Reason]).

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
-spec handle_config_req/4 :: (atom(), ne_binary(), ne_binary(), proplist()) -> pid().
handle_config_req(Node, ID, FsConf, _Data) ->
    spawn(fun() -> 
                  put(callid, ID),
                  try
                      EcallMgrConf = fsconf_to_sysconf(FsConf),
                      SysconfResp = ecallmgr_config:get(EcallMgrConf),
                      lager:debug("received sysconf response for ecallmngr config ~p", [EcallMgrConf]),
                      {ok, ConfigXml} = case EcallMgrConf of
                                            <<"acls">> -> ecallmgr_fs_xml:config_acl_xml(SysconfResp)
                                        end,
                      lager:debug("sending XML to ~w: ~s", [Node, ConfigXml]),
                      _ = freeswitch:fetch_reply(Node, ID, ConfigXml)
                  catch 
                      throw:_T ->
                          lager:debug("config request failed: thrown ~w", [_T]),
                          _ = freeswitch:fetch_reply(Node, ID, ?EMPTYRESPONSE);
                      error:_E ->
                          lager:debug("config request failed: error ~p", [_E]),
                          _ = freeswitch:fetch_reply(Node, ID, ?EMPTYRESPONSE)
                  end
          end).

%%% FS conf keys are not necessarily the same as we store them, remap it
-spec fsconf_to_sysconf/1 :: (ne_binary()) -> ne_binary().
fsconf_to_sysconf(FsConf) ->
  case FsConf of
    <<"acl.conf">> -> <<"acls">>
  end.
