-module(connection_supervisor).

-behaviour(gen_server).

-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

start_link([Args]) ->
    gen_server:start_link(?MODULE, Args, []).

init(InitialState) ->
    {ok, InitialState}.  

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({new_connection, Acceptor, Socket}, InitialState) ->
    Worker = proc_lib:spawn_link(bifrost, establish_control_connection, [Socket, InitialState]),
            Acceptor ! {ack, Worker},
    {noreply, InitialState}.

terminate(_Reason, _State) ->
    ok.