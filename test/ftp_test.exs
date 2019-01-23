defmodule FtpTest do
  use ExUnit.Case, async: false

  @server_name :test_server
  @test_addr "127.0.0.1"
  @test_port 7701
  @max_connections 50

  setup do
    Application.ensure_started(:ftp)
  end

  test "Try to connect max_connections times, expect all connections to be successful" do
    start_server()

    ## Will return a list containing value of {:ok, pid} or {:error, error}
    results = for _x <- 1..@max_connections, do: :ftp.open(to_charlist(@test_addr), @test_port)

    ## actual_results will be a list of booleans
    {ftp_pids, actual_results} = analyse_results(results)

    close_ftp_connections(ftp_pids)

    expected_results = for _x <- 1..@max_connections, do: true

    stop_server()

    assert expected_results == actual_results
  end

  test "Try to connect max_connections+1 times, expect the last time to fail" do
    start_server()

    ## Will return a list containing value of {:ok, pid} or {:error, error}
    results =
      for _x <- 1..(@max_connections + 1), do: :ftp.open(to_charlist(@test_addr), @test_port)

    ## actual_results will be a list of booleans
    {ftp_pids, actual_results} = analyse_results(results)

    close_ftp_connections(ftp_pids)

    expected_results = for _x <- 1..@max_connections, do: true
    ## add last case as a failure
    expected_results = expected_results ++ [false]

    stop_server()

    assert expected_results == actual_results
  end

  ## =========================================================== ##
  ## SOME HELPER FUNCTIONS
  ## =========================================================== ##

  defp analyse_results(results) do
    boolean_results =
      for result <- results do
        case result do
          {:ok, _pid} -> true
          {:error, _} -> false
        end
      end

    {results, boolean_results}
  end

  ## close ftp connections from client side
  defp close_ftp_connections(ftp_connections) do
    for ftp_connection <- ftp_connections, do: close_ftp_connection(ftp_connection)
  end

  defp close_ftp_connection({:ok, pid}), do: :ftp.close(pid)
  defp close_ftp_connection({:error, _}), do: :ok

  defp start_server() do
    opts = [
      username: "user",
      password: "pass",
      max_connections: @max_connections
    ]

    root = Path.absname("") <> "/tmp/ftp_root"
    File.mkdir_p!(root)
    Ftp.start_server(@server_name, @test_addr, @test_port, root, opts)
  end

  defp stop_server() do
    Ftp.close_server(@server_name)
  end
end
