defmodule Ftp.Utils do
    @moduledoc """
    Module for various utility functions
    """
    require Logger

    @doc """
    Fuction to return:
      `:ok` when a table with name `name` of type `Atom` exists
      `{:error, :eexist}` when a table with name `name` of type `Atom` does not exist
      `{:error, :undef}` If an UndefinedFunctionError is returned, which can happen if the user is using OTP < 21
    """
    def ets_table_exists(name) when is_atom(name) do
        try do
          case :ets.whereis(name) do
            :undefined -> {:error, :eexist}
            _tid -> :ok
          end
        rescue
          ## ets.whereis was only added in OTP 21, so user will get this error if they try to use an older version
          UndefinedFunctionError -> {:error, :undef}
        end
    end

    def ets_lookup(name, item) do
      case ets_table_exists(name) do
        :ok -> :ets.lookup(name, item)
        error -> error
      end
    end

    @doc """
    Function to return all the active sessions for a given `server_name`.
    """
    @spec get_active_sessions(atom()) :: list() | nil
    def get_active_sessions(server_name) when is_atom(server_name) do
      case ets_lookup(server_name, :active_sessions) do
        [{:active_sessions, active_sessions}] -> active_sessions
        _ -> nil
      end
    end
  
    @doc """
    Function to close a session of id `session_id` of the ftp server `server_name`.
    """
    @spec close_session(atom(), binary()) :: :ok
    def close_session(server_name, session_id) when is_atom(server_name) and is_binary(session_id) do
      case ets_lookup(server_name, :active_sessions) do
        [{:active_sessions, active_sessions}] -> 
          new_active_sessions = 
          Enum.filter(active_sessions, fn conn_state ->
            stored_session_id = get_session_id(conn_state)
            if stored_session_id == session_id do
              port = get_port(conn_state)
              close_port(port, session_id)
              false
            else
              true
            end
          end)
          if new_active_sessions == active_sessions do
            Logger.info("Could not close session #{inspect session_id} as it does not exist.")
          end          
          :ets.insert(server_name, {:active_sessions, new_active_sessions})
        _ -> :ok
      end
      :ok
    end

    @doc """
    Function to close the `port` belonging to `session_id`
    """
    @spec close_port(port(), binary()) :: :ok
    def close_port(port, session_id) when is_port(port) and is_binary(session_id) do
      Logger.info("Closing port #{inspect port} for session #{inspect session_id}")
      Port.close(port)
    end
  
    def close_port(_port, _session_id) do
      :ok
    end
  
    @doc """
    Utility function to return the `Port` if present in `conn_state`
    """
    @spec get_port(tuple()) :: port() | nil
    def get_port(conn_state) when is_tuple(conn_state) do
      port_index = 15 ## port location in conn_state
      conn_state
      |> Tuple.to_list()
      |> Enum.at(port_index)
    end
  
    @doc """
    Utility function to return the session from `conn_state`
    """
    @spec get_session_id(tuple()) :: binary() | nil
    def get_session_id(conn_state) when is_tuple(conn_state) do
      session_index = 8 ## %Ftp.Bifrost{} struct location in conn_state
      session_state = 
      conn_state
      |> Tuple.to_list()
      |> Enum.at(session_index)

      if is_map(session_state) do
        Map.get(session_state, :session)
      else
        nil
      end
    end
end
