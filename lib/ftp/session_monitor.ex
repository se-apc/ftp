defmodule Ftp.SessionMonitor do

    use GenServer
    require Logger

    @type session_timeout :: pos_integer()
    @type socket :: port()
    @type session :: {socket(), session_timeout(), reference()}

    def update_session(session) do
        add_session(session)
    end

    def add_session(session) do
        GenServer.cast(__MODULE__, {:add_session, session})
    end

    def remove_session(socket) do
        GenServer.cast(__MODULE__, {:remove_session, socket})
    end

    def start_link(_) do
        GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    def init(_) do
        sessions = []
        {:ok, sessions}
    end

    def handle_info({:close_socket, socket}, sessions) do
        Logger.info("Attemping to close socket #{inspect(socket)}...")
        close_socket(socket)
        other_sessions =
        sessions
        |> Enum.map(fn session = {s, _, ref} ->
                if s == socket do
                    Logger.info("Attempting to close socket's ref #{inspect(ref)}...")
                    cancel_timer(ref)
                end
                session
            end)
        |> remove_session_from_list(socket)
        {:noreply, other_sessions}
    end

    def handle_cast({:add_session, session = {socket, session_timeout}}, sessions) do
        case Enum.filter(sessions, fn {s, _, _} -> s == socket end) do
            [] ->
                Logger.info("Could not find session: #{inspect(session)}. Will add new one...")
                ref = Process.send_after(self(), {:close_socket, socket}, session_timeout)
                new_session = {socket, session_timeout, ref}
                {:noreply, sessions ++ [new_session]}
            [session = {_socket, _old_session_timeout, old_ref}] ->
                Logger.info("Found Session: #{inspect(session)}")
                cancel_timer(old_ref)
                other_sessions = remove_session_from_list(sessions, socket)
                ref = Process.send_after(self(), {:close_socket, socket}, session_timeout)
                new_session = {socket, session_timeout, ref}
                {:noreply, other_sessions ++ [new_session]}
        end
    end

    def handle_cast({:remove_session, socket}, sessions) do
        handle_info({:close_socket, socket}, sessions)
    end

    defp cancel_timer(ref) do
        unless Process.read_timer(ref) == false do
            Logger.info("Cancelling #{inspect(ref)}...")
            Process.cancel_timer(ref)
        else
            Logger.info("Ref #{inspect(ref)} not found!")
        end
    end

    defp remove_session_from_list(sessions, socket) do
        Logger.info("Removing #{inspect(socket)} from sessions (#{inspect(sessions)})...")
        new_sessions = Enum.reject(sessions, fn {s, _, _} -> s == socket end)
        Logger.info("New sessions: #{inspect(new_sessions)}")
        new_sessions
    end

    defp close_socket(socket) do
        unless Port.info(socket) == nil do
            Logger.info("Closing socket #{inspect(socket)}...")
            :gen_tcp.shutdown(socket, :read_write)
        else
            Logger.info("Could not close #{inspect(socket)}. nil value")
        end
    end

end