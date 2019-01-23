defmodule Ftp.Supervisor do
  use Supervisor
  require Logger
  import Ftp.Utils

  @server_name __MODULE__

  def start_link(args \\ []) do
    Supervisor.start_link(__MODULE__, args, name: @server_name)
  end

  def init(_args) do
    Supervisor.init([], strategy: :one_for_one)
  end

  def start_server(name, options) when is_binary(name) do
    name
    |> String.to_atom()
    |> start_server(options)
  end

  def start_server(name, options) do
    unless ets_table_exists?(name), do: :ets.new(name, [:public, :named_table])
    Supervisor.start_child(@server_name, %{
      id: name,
      start: {:bifrost, :start_link, [Ftp.Bifrost, options]}
    })
  end

  def stop_server(name) when is_binary(name) do
    name
    |> String.to_atom()
    |> stop_server()
  end

  def stop_server(name) do
    Supervisor.terminate_child(@server_name, name)
    Supervisor.delete_child(@server_name, name)
    if ets_table_exists?(name), do: :ets.delete(name)
    :ok
  end
end
