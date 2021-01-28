defmodule Ftp.SessionMonitor do

    use GenServer
    require Logger

    @type session_timeout :: pos_integer()
    @type socket :: port()
    @type session :: {socket(), session_timeout(), reference()}

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
        close_socket(socket)
        Logger.info("Sessions == #{inspect sessions}")
        other_sessions =
        sessions
        |> Enum.map(fn session = {s, _, ref} ->
                if s == socket, do: cancel_timer(ref)
                session
            end)
        |> remove_session_from_list(socket)
        {:noreply, other_sessions}
    end

    def handle_cast({:add_session, session = {socket, session_timeout}}, sessions) do
        case Enum.filter(sessions, fn {s, _, _} -> s == socket end) do
            [] ->
                Logger.info("Could not find session: #{inspect session}")
                ref = Process.send_after(self(), {:close_socket, socket}, session_timeout)
                new_session = {socket, session_timeout, ref}
                {:noreply, sessions ++ [new_session]}
            [session = {_socket, _old_session_timeout, old_ref}] ->
                Logger.info("Found Session: #{inspect session}")
                cancel_timer(old_ref)

                other_sessions = remove_session_from_list(sessions, socket)
                Logger.info("Other sessions = #{inspect other_sessions}")
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
            Logger.info("Cancelling old ref...")
            Process.cancel_timer(ref)
        end
    end

    defp remove_session_from_list(sessions, socket) do
        Enum.reject(sessions, fn {s, _, _} -> s == socket end)
    end

    defp close_socket(socket) do
        unless Port.info(socket) == nil do
            :gen_tcp.shutdown(socket, :read_write)
        end
    end

end