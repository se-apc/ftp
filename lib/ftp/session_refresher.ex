defmodule Ftp.SessionRefresher do

    use GenServer
    require Logger

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
    def init(_), do: {:ok, %{}}
    def handle_info({:refresh_session, module_state}, state) do
        Logger.warn("Refreshing for data transfer...")
        Ftp.Bifrost.refresh_session(module_state)
        {:noreply, state}
    end
end