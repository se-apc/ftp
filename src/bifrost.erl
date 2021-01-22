%%%-------------------------------------------------------------------
%%% File    : bifrost.erl
%%% Author  : Ryan Crum <ryan@ryancrum.org>
%%% Description : Pluggable FTP Server gen_server
%%%-------------------------------------------------------------------

-module(bifrost).

-behaviour(gen_server).
-include("bifrost.hrl").

-export([start_link/3, establish_control_connection/2, await_connections/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(FEATURES, [ "UTF8" ]).
-define(DEFAULT_MAX_SESSIONS, 10).
-define(DEFAULT_CURRENT_SESSIONS, 0).

% This is the time (in minutes) the socket will stay open while it is waiting for a username and/or password
-define(INITIAL_PROMPT_SOCKET_TIMEOUT, 1).

default(Expr, Default) ->
    case Expr of
        undefined ->
            Default;
        _ ->
            Expr
    end.

-spec ucs2_to_utf8(
  binary()
  | maybe_improper_list(
      binary() | maybe_improper_list(any(), binary() | []) | char(),
      binary() | []
    )
) -> [byte()].

ucs2_to_utf8(String) ->
    erlang:binary_to_list(unicode:characters_to_binary(String, utf8)).

start_link(HookModule, Opts, ServerName) ->
    connection_monitor:start_link(ServerName),
    gen_server:start_link(?MODULE, [HookModule, Opts], []).

%% gen_server callbacks implementation
init([HookModule, Opts]) ->
    Port = default(proplists:get_value(port, Opts), 21),
    Ssl = default(proplists:get_value(ssl, Opts), false),
    SslKey = proplists:get_value(ssl_key, Opts),
    SslCert = proplists:get_value(ssl_cert, Opts),
    CaSslCert = proplists:get_value(ca_ssl_cert, Opts),
    UTF8 = proplists:get_value(utf8, Opts),
    ServerName = proplists:get_value(server_name, Opts),
    IpOpts = case proplists:get_value(ip_address, Opts) of
                undefined ->
                    [];
                IfAddr ->
                    [{ifaddr, IfAddr}]
             end,
    case listen_socket(Port, [{active, false}, {reuseaddr, true}, list] ++ IpOpts) of
        {ok, Listen} ->
            IpAddress = default(proplists:get_value(ip_address, Opts), get_socket_addr(Listen)),
            InitialState = #connection_state{module=HookModule,
                                             ip_address=IpAddress,
                                             ssl_allowed=Ssl,
                                             ssl_key=SslKey,
                                             ssl_cert=SslCert,
                                             ssl_ca_cert=CaSslCert,
                                             utf8=UTF8},
            {ok, Supervisor} = connection_supervisor:start_link([HookModule:init(InitialState, Opts)]),
            connection_monitor:monitor(ServerName, Supervisor),
            proc_lib:spawn_link(?MODULE,
                                await_connections,
                                [Listen, Supervisor]),
            {ok, {listen_socket, Listen}};
        {error, Error} ->
            {stop, Error}
    end.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, {listen_socket, Socket}) ->
    gen_tcp:close(Socket);
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

get_socket_addr(Socket) ->
    case inet:sockname(Socket) of
        {ok, {Addr, _}} ->
            Addr
    end.

get_socket_client_addr(Socket) ->
    case inet:peername(Socket) of
        {ok, {Addr, _}} -> Addr;
        {error, _Error} -> nil
    end.

listen_socket(Port, TcpOpts) ->
    gen_tcp:listen(Port, TcpOpts).

await_connections(Listen, Supervisor) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            Supervisor ! {new_connection, self(), Socket},
            receive
                {ack, Worker} ->
                    %% ssl:ssl_accept/2 will return {error, not_owner} otherwise
                    case gen_tcp:controlling_process(Socket, Worker) of
                        ok -> ok;
                        
                        % treat {error, closed} as the case when we close the socket ourselves when max_sessions has been reached
                        {error, closed} -> ok
                    end                        
            end;
        _Error ->
            exit(bad_accept)
    end,
    await_connections(Listen, Supervisor).

% need because ets:whereis was not added until OTP 21
ets_whereis(TableName) -> 
    try
        ets:whereis(TableName)
    catch
        error:undef -> undefined
    end.

establish_control_connection(Socket, InitialState) ->
    ModuleState = InitialState#connection_state.module_state,
    Name = maps:get(server_name, ModuleState),
    [{max_sessions, MaxSessions}] = 
    case ets_whereis(Name) of
          undefined -> [{max_sessions, ?DEFAULT_MAX_SESSIONS}];
          _ -> ets:lookup(Name, max_sessions)
    end,

    [{current_sessions, CurrentSessions}] = 
    case ets_whereis(Name) of
          undefined -> [{current_sessions, ?DEFAULT_CURRENT_SESSIONS}];
          _ -> ets:lookup(Name, current_sessions)
    end,
    
    if 
        CurrentSessions>=MaxSessions -> 
            respond(InitialState, {gen_tcp, Socket}, 421, "Maximum sessions reached"),
            gen_tcp:close(Socket),
            {error, max_sessions_reached}; 
        true -> 
            respond(InitialState, {gen_tcp, Socket}, 220, "FTP Server Ready"),
            IpAddress = case InitialState#connection_state.ip_address of
                            undefined -> get_socket_addr(Socket);
                            {0, 0, 0, 0} -> get_socket_addr(Socket);
                            {0, 0, 0, 0, 0, 0} -> get_socket_addr(Socket);
                            Ip -> Ip
                        end,
            NewCurrentSessions = CurrentSessions + 1,
            case ets_whereis(Name) of
                undefined -> ok;
                _ -> ets:insert(Name, {current_sessions, NewCurrentSessions})
            end,
            control_loop(none,
                        {gen_tcp, Socket},
                        InitialState#connection_state{control_socket=Socket, ip_address=IpAddress}),
            NewCurrentSessionsAfterExit = NewCurrentSessions - 1,
            case ets_whereis(Name) of
                undefined -> ok;
                _ -> ets:insert(Name, {current_sessions, NewCurrentSessionsAfterExit})
            end    
        
    end.

% Retrieve the session timeout from the state
get_session_timeout(#{session_timeout := SessionTimeout}) ->
    timer:minutes(SessionTimeout);
% This case will be called when there is no session timeout given, and when the server is wait for the user to enter their username and/or password
get_session_timeout(_) ->
    timer:minutes(?INITIAL_PROMPT_SOCKET_TIMEOUT).


control_loop(HookPid, {SocketMod, RawSocket} = Socket, State) ->
    ModuleState = State#connection_state.module_state,
    UserMap = maps:get(user, ModuleState),
    SessionTimeout = get_session_timeout(UserMap),
    SessionInfo = {self(), UserMap},
    case SocketMod:recv(RawSocket, 0, SessionTimeout) of
        {ok, Input} ->
            Input = {Command, Arg} = parse_input(Input),
            error_logger:info_report({bifrost, client_request, Input, SessionInfo}),
            case ftp_command(Socket, State, Command, Arg) of
                {ok, NewState} ->
                    if is_pid(HookPid) =:= false ->
                            control_loop(HookPid, Socket, NewState);
                    true ->
                            HookPid ! {new_state, self(), NewState},
                            receive
                                {ack, HookPid} ->
                                    control_loop(HookPid, Socket, NewState);
                                {done, HookPid} ->
                                    {error, closed}
                            end
                    end;
                {new_socket, NewState, NewSock} ->
                    control_loop(HookPid, NewSock, NewState);
                {error, timeout} ->
                    respond(State, Socket, 412, "Timed out. Closing control connection."),
                    error_logger:error_report({bifrost, connection_terminated, timeout, SessionInfo}),
                    end_session(State, Socket, e_server_logout_successful),
                    {error, timeout};
                {error, closed} ->
                    error_logger:error_report({bifrost, connection_terminated, connection_closed, SessionInfo}),
                    {error, closed};
                quit ->
                    error_logger:warning_report({bifrost, connection_terminated, quit_by_user, SessionInfo}),
                    end_session(State, Socket, e_user_logout_successful)
            end;
        {error, timeout} ->
            error_logger:error_report({bifrost, connection_terminated, inactivity_timeout, SessionInfo}),
            end_session(State, Socket, e_server_logout_successful);
        {error, Reason} ->
            error_logger:error_report({bifrost, connection_terminated, Reason, SessionInfo}),
            end_session(State, Socket, e_server_logout_successful)
    end.

end_session(State, {SocketMod, RawSocket}, Reason) ->
    Mod = State#connection_state.module,
    Mod:disconnect(State, Reason),    
    SocketMod:close(RawSocket),
    {ok, quit}.

respond(State, Socket, ResponseCode) ->
    respond(State, Socket, ResponseCode, response_code_string(ResponseCode)).

respond(State, {SocketMod, Socket}, ResponseCode, Message) ->
    ModuleState = State#connection_state.module_state,
    UserMap = maps:get(user, ModuleState),
    SessionInfo = {erlang:self(), UserMap},
    Line = integer_to_list(ResponseCode) ++ " " ++ ucs2_to_utf8(Message) ++ "\r\n",
    error_logger:info_report({bifrost, server_response, Line, SessionInfo}),
    SocketMod:send(Socket, Line).

respond_raw({SocketMod, Socket}, Line) ->
    SocketMod:send(Socket, ucs2_to_utf8(Line) ++ "\r\n").

ssl_options(State) ->
    [{keyfile, State#connection_state.ssl_key},
     {certfile, State#connection_state.ssl_cert},
     {cacertfile, State#connection_state.ssl_ca_cert}].

data_connection(ControlSocket, State) ->
    respond(State, ControlSocket, 150),
    case establish_data_connection(State) of
        {ok, DataSocket} ->
            case State#connection_state.protection_mode of
                clear ->
                    {gen_tcp, DataSocket};
                private ->
                    case ssl:ssl_accept(DataSocket,
                                        ssl_options(State)) of
                        {ok, SslSocket} ->
                            {ssl, SslSocket};
                        E ->
                            respond(State, ControlSocket, 425),
                            throw({error, E})
                    end
            end;
        {error, Error} ->
            respond(State, ControlSocket, 425),
            throw(Error)
    end.


%% passive -- accepts an inbound connection
establish_data_connection(State = #connection_state{pasv_listen={passive, Listen, _}}) ->
    % Here we are preventing a potential bounce attack, by  not allowing any host other than the host the 
    % the control connection is made on, to open a data connection. Idea  came from here https://seclists.org/bugtraq/1995/Jul/46
    case gen_tcp:accept(Listen) of 
        {error, Error} -> {error, Error};
        {ok, Socket} ->
            {ok, {ClientDataIPAddress, _}} = inet:peername(Socket),
            ClientControlIPAddress = State#connection_state.client_ip_address,
            if ClientControlIPAddress == ClientDataIPAddress ->
                {ok, Socket};
            true ->
                gen_tcp:shutdown(Socket, read_write),
                io:fwrite('Client\'s Data and Control Ips do not match.  Control IP: ~w   Potential Data IP: ~w\n', [ClientControlIPAddress, ClientDataIPAddress]),
                {error, potential_bounce_attack}
            end
    end;





%% active -- establishes an outbound connection
establish_data_connection(State = #connection_state{data_port={active, ClientDataIPAddress, ClientDataPort}}) ->
    ClientControlIPAddress = State#connection_state.client_ip_address,
    % Here we are preventing a potential bounce attack, by  not allowing any host other than the host the 
    % the control connection is made on, to open a data connection. Idea  came from here https://seclists.org/bugtraq/1995/Jul/46
    if ClientControlIPAddress == ClientDataIPAddress ->
            % io:fwrite('IPs equal\n'),
            gen_tcp:connect(ClientDataIPAddress, ClientDataPort, [{active, false}, binary]);
        true ->
            io:fwrite('Client\'s Data and Control Ips do not match.  Control IP: ~w   Potential Data IP: ~w\n', [ClientControlIPAddress, ClientDataIPAddress]),
            {error, potential_bounce_attack}
    end.

pasv_connection(ControlSocket, State) ->
    case State#connection_state.pasv_listen of
        {passive, PasvListen, _} ->
                                                % We should only have one passive socket open at a time, so close the current one
                                                % and open a new one.
            gen_tcp:close(PasvListen),
            pasv_connection(ControlSocket, State#connection_state{pasv_listen=undefined});
        undefined ->
            case listen_socket(0, [{active, false}, binary]) of
                {ok, Listen} ->
                    {ok, {_, Port}} = inet:sockname(Listen),
                    Ip = State#connection_state.ip_address,
                    PasvSocketInfo = {passive,
                                      Listen,
                                      {Ip, Port}},
                    {P1,P2} = format_port(Port),
                    {S1,S2,S3,S4} = Ip,
                    respond(State, ControlSocket,
                            227,
                            lists:flatten(
                              io_lib:format("Entering Passive Mode (~p,~p,~p,~p,~p,~p)",
                                            [S1,S2,S3,S4,P1,P2]))),

                    {ok,
                     State#connection_state{pasv_listen=PasvSocketInfo}};
                {error, _} ->
                    respond(State, ControlSocket, 425),
                    {ok, State}
            end
    end.

%% FTP COMMANDS

ftp_command(Socket, State, Command, RawArg) ->
    Mod = State#connection_state.module,
    case unicode:characters_to_list(erlang:list_to_binary(RawArg), utf8) of
        { error, List, _RestData } ->
            error_logger:warning_report({bifrost, invalid_utf8, List}),
            respond(State, Socket, 501),
            {ok, State};
        { incomplete, List, _Binary } ->
            error_logger:warning_report({bifrost, incomplete_utf8, List}),
            respond(State, Socket, 501),
            {ok, State};
        Arg ->
            ftp_command(Mod, Socket, State, Command, Arg)
    end.

ftp_command(_Mod, Socket, State, quit, _) ->
    respond(State, Socket, 221, "Goodbye."),
    quit;

ftp_command(_, Socket, State, pasv, _) ->
    pasv_connection(Socket, State);

ftp_command(_, {_, RawSocket} = Socket, State, auth, Arg) ->
    if State#connection_state.ssl_allowed =:= false ->
            respond(State, Socket, 500),
            {ok, State};
       true ->
            case string:to_lower(Arg) of
                "tls" ->
                    respond(State, Socket, 234, "Command okay."),
                    case ssl:ssl_accept(RawSocket,
                                        ssl_options(State)) of
                        {ok, SslSocket} ->
                            {new_socket,
                             State#connection_state{ssl_socket=SslSocket},
                             {ssl, SslSocket}};
                        _ ->
                            respond(State, Socket, 500),
                            {ok, State}
                    end;
                _ ->
                    respond(State, Socket, 502, "Unsupported security extension."),
                    {ok, State}
            end
    end;

ftp_command(_, Socket, State, prot, Arg) ->
    ProtMode = case string:to_lower(Arg) of
                   "c" -> clear;
                   _ -> private
               end,
    respond(State, Socket, 200),
    {ok, State#connection_state{protection_mode=ProtMode}};

ftp_command(_, Socket, State, pbsz, "0") ->
    respond(State, Socket, 200),
    {ok, State};

ftp_command(_, Socket, State, user, Arg) ->
    respond(State, Socket, 331),
    {ok, State#connection_state{user_name=Arg}};

ftp_command(_, Socket, State, port, Arg) ->
    case parse_address(Arg) of
        {ok, {ClientDataIPAddress, ClientDataPort}} ->
            ClientControlIPAddress = State#connection_state.client_ip_address,
            
            % Here we are preventing a potential bounce attack, by  not allowing any host other than the host the 
            % the control connection is made on, to open a data connection. Idea  came from here https://seclists.org/bugtraq/1995/Jul/46
            NewState =             
            if ClientDataIPAddress == ClientControlIPAddress ->
                respond(State, Socket, 200),
                State#connection_state{data_port = {active, ClientDataIPAddress, ClientDataPort}};
            true ->
                io:fwrite('Client\'s Data and Control Ips do not match.  Control IP: ~w   Potential Data IP: ~w\n', [ClientControlIPAddress, ClientDataIPAddress]),
                respond(State, Socket, 452, "Error parsing address."),
                State 
            end,
            {ok, NewState};
        _ ->
            respond(State, Socket, 452, "Error parsing address.")
    end;

ftp_command(Mod, {_SocketMod, RawSocket} = Socket, State, pass, Arg) ->
    ClientIpAddress = get_socket_client_addr(RawSocket),
    case Mod:login(State#connection_state{client_ip_address=ClientIpAddress}, State#connection_state.user_name, Arg) of
        {true, NewState} ->
            respond(State, Socket, 230),
            {ok, NewState#connection_state{authenticated_state=authenticated}};
        _ ->
            respond(State, Socket, 530, "Login incorrect."),
            quit
    end;

%% based of rfc2389
ftp_command(_Mod, Socket, State, feat, _Arg) ->
    respond_raw(Socket, "211- Extensions supported:"),
    lists:map(	fun	({Feature, FeatureParams}) -> respond_raw(Socket, " " ++ Feature ++ " " ++ FeatureParams);
                      (Feature) -> respond_raw(Socket, " " ++ Feature)
                end,
                ?FEATURES),
    respond(State, Socket, 211, "End"),
    {ok, State};

%% ^^^ from this point down every command requires authentication ^^^

ftp_command(_, Socket, State=#connection_state{authenticated_state=unauthenticated}, _, _) ->
    respond(State, Socket, 530),
    {ok, State};

ftp_command(_, Socket, State, rein, _) ->
    respond(State, Socket, 200),
    {ok,
     State#connection_state{user_name=none,authenticated_state=unauthenticated}};

ftp_command(Mod, Socket, State, abor, Arg) ->
    case Mod:abort(State, Arg) of
        {ok, NewState} ->
            respond(State, Socket, 426),
            {ok, NewState};
        {error, _} ->
            {ok, State}
    end;

ftp_command(Mod, Socket, State, pwd, _) ->
    respond(State, Socket, 257, "\"" ++ Mod:current_directory(State) ++ "\""),
    {ok, State};

ftp_command(Mod, Socket, State, cdup, _) ->
    ftp_command(Mod, Socket, State, cwd, "..");

ftp_command(Mod, Socket, State, cwd, Arg) ->
    case Mod:change_directory(State, Arg) of
        {ok, NewState} ->
            respond(State, Socket, 250, "directory changed to \"" ++ Mod:current_directory(NewState) ++ "\""),
            {ok, NewState};
        {error, _} ->
            respond(State, Socket, 550, "Unable to change directory"),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, mkd, Arg) ->
    case Mod:make_directory(State, Arg) of
        {ok, NewState} ->
            respond(State, Socket, 250, "\"" ++ Arg ++ "\" directory created."),
            {ok, NewState};
        {error, _} ->
            respond(State, Socket, 550, "Unable to create directory"),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, nlst, Arg) ->
    case Mod:list_files(State, Arg) of
        {error, NewState} ->
            respond(State, Socket, 451),
            {ok, NewState};
        Files ->
            DataSocket = data_connection(Socket, State),
            list_file_names_to_socket(DataSocket, Files),
            respond(State, Socket, 226),
            bf_close(DataSocket),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, list, Arg) ->
    case Mod:list_files(State, Arg) of
        {error, _} ->
            respond(State, Socket, 451),
            {ok, State};
        Files ->
            DataSocket = data_connection(Socket, State),
            list_files_to_socket(DataSocket, Files),
            respond(State, Socket, 226),
            bf_close(DataSocket),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, rmd, Arg) ->
    case Mod:remove_directory(State, Arg) of
        {ok, NewState} ->
            respond(State, Socket, 200),
            {ok, NewState};
        {error, _} ->
            respond(State, Socket, 550),
            {ok, State}
    end;

ftp_command(_, Socket, State, syst, _) ->
    respond(State, Socket, 215, "UNIX Type: L8"),
    {ok, State};

ftp_command(Mod, Socket, State, dele, Arg) ->
    case Mod:remove_file(State, Arg) of
        {ok, NewState} ->
            respond(State, Socket, 200),
            {ok, NewState};
        {error, _} ->
            respond(State, Socket, 450),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, stor, Arg) ->
    DataSocket = data_connection(Socket, State),
    Fun = fun() ->
                  case bf_recv(DataSocket) of
                      {ok, Data} ->
                          {ok, Data, size(Data)};
                      {error, closed} ->
                          done
                  end
          end,
    RetState = case Mod:put_file(State, Arg, write, Fun) of
                   {ok, NewState} ->
                       respond(State, Socket, 226),
                       NewState;
                   {error, Info} ->
                       respond(State, Socket, 451, io_lib:format("Error ~p when storing a file.", [Info])),
                       State
               end,
    bf_close(DataSocket),
    {ok, RetState};

ftp_command(_, Socket, State, type, Arg) ->
    case Arg of
        "I" ->
            respond(State, Socket, 200);
        "A" ->
            respond(State, Socket, 200);
        _->
            respond(State, Socket, 501, "Only TYPE I or TYPE A may be used.")
    end,
    {ok, State};

ftp_command(Mod, Socket, State, site, Arg) ->
    [Command | Sargs] = string:tokens(Arg, " "),
    case Mod:site_command(State, list_to_atom(string:to_lower(Command)), string:join(Sargs, " ")) of
        {ok, NewState} ->
            respond(State, Socket, 200),
            {ok, NewState};
        {error, not_found} ->
            respond(State, Socket, 500),
            {ok, State};
        {error, _} ->
            respond(State, Socket, 501, "Error completing command."),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, site_help, _) ->
    case Mod:site_help(State) of
        {ok, []} ->
            respond(State, Socket, 500);
        {error, _} ->
            respond(State, Socket, 500);
        {ok, Commands} ->
            respond_raw(Socket, "214-The following commands are recognized"),
            lists:map(fun({CmdName, Descr}) ->
                              respond_raw(Socket, CmdName ++ " : " ++ Descr)
                      end,
                      Commands),
            respond(State, Socket, 214, "Help OK")
    end,
    {ok, State};

ftp_command(Mod, Socket, State, help, Arg) ->
    LowerArg =  string:to_lower(Arg),
    case LowerArg of
        "site" ->
            ftp_command(Mod, Socket, State, site_help, undefined);
        _ ->
            respond(State, Socket, 500),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, retr, Arg) ->
    try
        case Mod:get_file(State, Arg) of
            {ok, Fun, NewState} ->
                % This must be async in order to abort it
                spawn_link(
                    fun () ->
                        DataSocket = data_connection(Socket, State),
                        {ok, _NewState} = write_fun(DataSocket, Fun),
                        respond(State, Socket, 226),
                        bf_close(DataSocket)
                    end),

                {ok, NewState};
            {error, Reason} ->
                error_logger:error_report({bifrost, get_file_failed, Reason, Arg}),
                respond(State, Socket, 550, io_lib:format("Get '~s' failed: ~p", [Arg, Reason])),
                {ok, State}
        end
        catch
            CrashError ->
                error_logger:error_report({bifrost, get_file_crashed, CrashError, Arg}),
                respond(State, Socket, 550, io_lib:format("Get '~s' failed: Unknown", [Arg])),
                {ok, State}
        end;

ftp_command(Mod, Socket, State, rest, Arg) ->
    try
        case Mod:restart(State, Arg) of
            {ok, NewState} ->
                respond(State, Socket, 350, "Rest Supported. Offset set to " ++ Arg),
                {ok, NewState};
            error ->
                respond(State, Socket, 550),
                {ok, State}
        end
    catch
        _ ->
            respond(State, Socket, 550),
            {ok, State}
    end;

ftp_command(Mod, Socket, State, mdtm, Arg) ->
    case Mod:file_info(State, Arg) of
        {ok, FileInfo} ->
            respond(State, Socket,
                    213,
                    format_mdtm_date(FileInfo#file_info.mtime));
        _ ->
            respond(State, Socket, 550)
    end,
    {ok, State};

ftp_command(_, Socket, State, rnfr, Arg) ->
    respond(State, Socket, 350, "Ready for RNTO."),
    {ok, State#connection_state{rnfr=Arg}};

ftp_command(Mod, Socket, State, rnto, Arg) ->
    case State#connection_state.rnfr of
        undefined ->
            respond(State, Socket, 503, "RNFR not specified."),
            {ok, State};
        Rnfr ->
            case Mod:rename_file(State, Rnfr, Arg) of
                {error, _} ->
                    respond(State, Socket, 550),
                    {ok, State};
                {ok, NewState} ->
                    respond(State, Socket, 250, "Rename successful."),
                    {ok, NewState#connection_state{rnfr=undefined}}
            end
    end;

ftp_command(Mod, Socket, State, xcwd, Arg) ->
    ftp_command(Mod, Socket, State, cwd, Arg);

ftp_command(Mod, Socket, State, xcup, Arg) ->
    ftp_command(Mod, Socket, State, cdup, Arg);

ftp_command(Mod, Socket, State, xmkd, Arg) ->
    ftp_command(Mod, Socket, State, mkd, Arg);

ftp_command(Mod, Socket, State, xpwd, Arg) ->
    ftp_command(Mod, Socket, State, pwd, Arg);

ftp_command(Mod, Socket, State, xrmd, Arg) ->
    ftp_command(Mod, Socket, State, rmd, Arg);

ftp_command(_Mod, Socket, State, feat, _Arg) ->
    respond_raw(Socket, "211-Features"),
    case State#connection_state.utf8 of
        true ->
            respond_raw(Socket, " UTF8");
        _ ->
            ok
    end,
    respond(State, Socket, 211, "End"),
    {ok, State};

ftp_command(_Mod, Socket, State, opts, Arg) ->
    case string:to_upper(Arg) of
        "UTF8 ON" when State#connection_state.utf8 =:= true ->
            respond(State, Socket, 200, "Accepted");
        _ ->
            respond(State, Socket, 501)
    end,
    {ok, State};

ftp_command(Mod, Socket, State, size, Arg) ->
    case Mod:size(State, Arg) of
      {"-1", _State} -> respond(State, Socket, 550); % error
      {FileSize, _State} -> respond(State, Socket, 213, FileSize)
    end,
    {ok, State};

ftp_command(_, Socket, State, Command, _Arg) ->
    error_logger:warning_report({bifrost, unrecognized_command, Command}),
    respond(State, Socket, 500),
    {ok, State}.

write_fun(Socket, Fun) ->
    case Fun(1024) of
        {ok, Bytes, NextFun} ->
            bf_send(Socket, Bytes),
            write_fun(Socket, NextFun);
        {done, NewState} ->
            {ok, NewState}
    end.

strip_newlines(S) ->
    lists:foldr(fun(C, A) ->
                        string:strip(A, right, C) end,
                S,
                "\r\n").

parse_input(Input) ->
    Tokens = string:tokens(Input, " "),
    [Command | Args] = lists:map(fun(S) -> strip_newlines(S) end,
                                 Tokens),
    {list_to_atom(string:to_lower(Command)), string:join(Args, " ")}.

list_files_to_socket(DataSocket, Files) ->
    lists:map(fun(Info) ->
                      bf_send(DataSocket,
                              ucs2_to_utf8(file_info_to_string(Info)) ++ "\r\n") end,
              Files),
    ok.

list_file_names_to_socket(DataSocket, Files) ->
    lists:map(fun(Info) ->
                      bf_send(DataSocket, ucs2_to_utf8(Info#file_info.name)++"\r\n") end,
              Files),
    ok.

bf_send({SockMod, Socket}, Data) ->
    SockMod:send(Socket, Data).

bf_close({SockMod, Socket}) ->
    SockMod:close(Socket).

bf_recv({SockMod, Socket}) ->
    SockMod:recv(Socket, 0).

%% Adapted from jungerl/ftpd.erl
% Unused codes commented out to apease dialyser
% response_code_string(110) -> "MARK yyyy = mmmm";
% response_code_string(120) -> "Service ready in nnn minutes.";
% response_code_string(125) -> "Data connection alredy open; transfere starting.";
response_code_string(150) -> "File status okay; about to open data connection.";
response_code_string(200) -> "Command okay.";
% response_code_string(202) -> "Command not implemented, superfluous at this site.";
% response_code_string(211) -> "System status, or system help reply.";
% response_code_string(212) -> "Directory status.";
% response_code_string(213) -> "File status.";
% response_code_string(214) -> "Help message.";
% response_code_string(215) -> "UNIX system type";
% response_code_string(220) -> "Service ready for user.";
% response_code_string(221) -> "Service closing control connection.";
% response_code_string(225) -> "Data connection open; no transfere in progress";
response_code_string(226) -> "Closing data connection.";
% response_code_string(227) -> "Entering Passive Mode (h1,h2,h3,h4,p1,p2).";
response_code_string(230) -> "User logged in, proceed.";
% response_code_string(250) -> "Requested file action okay, completed.";
% response_code_string(257) -> "PATHNAME created.";
response_code_string(331) -> "User name okay, need password.";
% response_code_string(332) -> "Need account for login.";
% response_code_string(350) -> "Requested file action pending further information.";
% response_code_string(421) -> "Service not available, closing control connection.";
response_code_string(425) -> "Can't open data connection.";
response_code_string(426) -> "Connection closed; transfere aborted.";
response_code_string(450) -> "Requested file action not taken.";
response_code_string(451) -> "Requested action not taken: local error in processing.";
% response_code_string(452) -> "Requested action not taken.";
response_code_string(500) -> "Syntax error, command unrecognized.";
response_code_string(501) -> "Syntax error in parameters or arguments.";
% response_code_string(502) -> "Command not implemented.";
% response_code_string(503) -> "Bad sequence of commands.";
% response_code_string(504) -> "Command not implemented for that parameter.";
% response_code_string(530) -> "Not logged in.";
% response_code_string(532) -> "Need account for storing files.";
response_code_string(550) -> "Requested action not taken.";
% response_code_string(551) -> "Requested action aborted: page type unkown.";
% response_code_string(552) -> "Requested file action aborted.";
% response_code_string(553) -> "Requested action not taken.";
response_code_string(_) -> "N/A".

%% Taken from jungerl/ftpd

file_info_to_string(Info) ->
    format_type(Info#file_info.type) ++
        format_access(Info#file_info.mode) ++ " " ++
        format_number(type_num(Info#file_info.type), 2, $ ) ++ " " ++
        format_number(Info#file_info.uid,5,$ ) ++ " " ++
        format_number(Info#file_info.gid,5,$ ) ++ " "  ++
        format_number(Info#file_info.size,8,$ ) ++ " " ++
        format_date(Info#file_info.mtime) ++ " " ++
        Info#file_info.name.

format_mdtm_date({{Year, Month, Day}, {Hours, Mins, Secs}}) ->
    lists:flatten(io_lib:format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B",
                                [Year, Month, Day, Hours, Mins, erlang:trunc(Secs)])).

format_date({Date, Time}) ->
    {Year, Month, Day} = Date,
    {Hours, Min, _} = Time,
    {LDate, _LTime} = calendar:local_time(),
    {LYear, _, _} = LDate,
    format_month_day(Month, Day) ++
        if LYear > Year ->
                format_year(Year);
           true ->
                format_time(Hours, Min)
        end.

format_month_day(Month, Day) ->
    io_lib:format("~s ~2.2w", [month(Month), Day]).

format_year(Year) ->
    io_lib:format(" ~5.5w", [Year]).

format_time(Hours, Min) ->
    io_lib:format(" ~2.2.0w:~2.2.0w", [Hours, Min]).

format_type(file) -> "-";
format_type(dir) -> "d";
format_type(_) -> "?".

type_num(file) ->
    1;
type_num(dir) ->
    4;
type_num(_) ->
    0.

format_access(Mode) ->
    format_rwx(Mode bsr 6) ++ format_rwx(Mode bsr 3) ++ format_rwx(Mode).

format_rwx(Mode) ->
    [if Mode band 4 == 0 -> $-; true -> $r end,
     if Mode band 2 == 0 -> $-; true -> $w end,
     if Mode band 1 == 0 -> $-; true -> $x end].

format_number(X, N, LeftPad) when X >= 0 ->
    Ls = integer_to_list(X),
    Len = length(Ls),
    if Len >= N -> Ls;
       true ->
            lists:duplicate(N - Len, LeftPad) ++ Ls
    end.

month(1) -> "Jan";
month(2) -> "Feb";
month(3) -> "Mar";
month(4) -> "Apr";
month(5) -> "May";
month(6) -> "Jun";
month(7) -> "Jul";
month(8) -> "Aug";
month(9) -> "Sep";
month(10) -> "Oct";
month(11) -> "Nov";
month(12) -> "Dec".

%% parse address on form:
%% d1,d2,d3,d4,p1,p2  => { {d1,d2,d3,d4}, port} -- ipv4
%% h1,h2,...,h32,p1,p2 => {{n1,n2,..,n8}, port} -- ipv6
%% Taken from jungerl/ftpd
parse_address(Str) ->
    paddr(Str, 0, []).

paddr([X|Xs],N,Acc) when X >= $0, X =< $9 -> paddr(Xs, N*10+(X-$0), Acc);
paddr([X|Xs],_N,Acc) when X >= $A, X =< $F -> paddr(Xs,(X-$A)+10, Acc);
paddr([X|Xs],_N,Acc) when X >= $a, X =< $f -> paddr(Xs, (X-$a)+10, Acc);
paddr([$,,$,|_Xs], _N, _Acc) -> error;
paddr([$,|Xs], N, Acc) -> paddr(Xs, 0, [N|Acc]);
paddr([],P2,[P1,D4,D3,D2,D1]) -> {ok,{{D1,D2,D3,D4}, P1*256+P2}};
paddr([],P2,[P1|As]) when length(As) == 32 ->
    case addr6(As,[]) of
        {ok,Addr} -> {ok, {Addr, P1*256+P2}};
        error -> error
    end;
paddr(_, _, _) -> error.

addr6([H4,H3,H2,H1|Addr],Acc) when H4<16,H3<16,H2<16,H1<16 ->
    addr6(Addr, [H4 + H3*16 + H2*256 + H1*4096 |Acc]);
addr6([], Acc) -> {ok, list_to_tuple(Acc)};
addr6(_, _) -> error.

format_port(PortNumber) ->
    [A,B] = binary_to_list(<<PortNumber:16>>),
    {A, B}.

