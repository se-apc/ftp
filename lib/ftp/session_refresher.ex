defmodule Ftp.SessionRefresher do

    use GenServer
    require Logger

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
    def init(_), do: {:ok, %{}}
    def handle_info({:refresh_session, module_state}, state) do
        session = Map.get(module_state, :session)
        Logger.info("Refreshing for data transfer #{inspect session}...")
        Ftp.Bifrost.refresh_session(module_state)
        {:noreply, state}
    end
end