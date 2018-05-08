defmodule Ftp.Supervisor do
  use DynamicSupervisor
  require Logger

  @server_name __MODULE__

  def start_link(args \\ []) do
    DynamicSupervisor.start_link(__MODULE__, args, name: @server_name)
  end

  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_server(name, options) when is_binary(name) do
    name
    |> String.to_atom()
    |> start_server(options)
  end

  def start_server(name, options) do
    DynamicSupervisor.start_child(@server_name, %{
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
    DynamicSupervisor.terminate_child(@server_name, name)
  end
end