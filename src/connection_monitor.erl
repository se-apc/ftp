-module(connection_monitor).

-behaviour(gen_server).

-export([start_link/1, monitor/2]).

%% gen_server callbacks
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

monitor(Name, Pid) ->
    gen_server:cast(Name, {monitor, Pid}).

start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

init(_) ->
    {ok, []}.  

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({monitor, Pid}, State) ->
    erlang:monitor(process, Pid),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, _Pid, normal}, State) ->
    {noreply, State};

handle_info({'DOWN', _Ref, process, _Pid, shutdown}, State) ->
    {noreply, State};

handle_info({'DOWN', _Ref, process, Pid, Info}, State) ->
    error_logger:error_msg("Control connection ~p crashed: ~p~n", [Pid, Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.