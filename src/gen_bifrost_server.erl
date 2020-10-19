%%%-------------------------------------------------------------------
%%% File    : gen_bifrost_server.erl
%%% Author  : Ryan Crum <ryan.j.crum@gmail.com>
%%% Description : Behavior for a Bifrost FTP server.
%%%-------------------------------------------------------------------

-module(gen_bifrost_server).

-callback init(State :: term(), Proplist :: term()) -> NewState :: term().
-callback login(State :: term(), Username :: binary(), Password :: binary()) -> {boolean(), NewState :: term()}.
-callback abort(State :: term(), Arg :: term()) -> NewState :: term().
-callback restart(State :: term(), Arg :: term()) -> NewState :: term().
-callback current_directory(State :: term()) -> Path :: binary().
-callback make_directory(State :: term(), Path :: binary()) -> NewState :: term().
-callback change_directory(State :: term(), Path :: binary()) -> NewState :: term().
-callback list_files(State :: term(), Path :: binary()) -> [FileInfo :: term()] | {error, NewState :: term()}.
-callback remove_directory(State :: term(), Path :: binary()) -> NewState :: term().
-callback size(State :: term(), Path :: binary()) -> {FileSize :: binary(), NewState :: term()}.
-callback remove_file(State :: term(), Path :: binary()) -> NewState :: term().
-callback put_file(State :: term(), FileName :: binary(), append | write, FunByteCount :: fun()) ->  NewState :: term().
-callback get_file(State :: term(), Path :: binary()) -> {ok, FunByteCount :: fun()} | error.
-callback file_information(State :: term(), Path :: binary()) -> {ok, FileInfo :: term()} | {error, ErrorCause :: term()}.
-callback rename_file(State :: term(), FromPath :: binary(), ToPath :: binary()) -> NewState :: term().
-callback site_command(State :: term(), CommandNameString :: binary(), CommandArgsString :: binary()) -> NewState :: term().
-callback site_help(State :: term()) -> {ok, [HelpInfo :: term()]} | {error, State :: term()}.
-callback disconnect(State :: term(), Reason :: term()) -> ok.
