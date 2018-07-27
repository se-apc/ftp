defmodule Ftp do
  require Logger

  @moduledoc """
  Documentation for the Ftp module. This is where the ftp server is started from
  """

  ## Uncomment the lines below to run this as an application from running `iex -S mix`

  use Application

  def start(_type, _args) do
    children = [
      # Starts a worker by calling: CommonData.Worker.start_link(arg)
      # {CommonData.Worker, arg},
      Ftp.Supervisor,
      Ftp.EventDispatcher
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Function to start the server.\n
  `name`: A name to uniquely identify this instance of the server as `String`\n
  `ip`: An ip address as `String`\n
  `port:` The port number server will run on\n
  `root_directory`: The root directory the server will run from and display to user. Given as an absolute path in the form of a `String`.\n
  `limit_viewable_dirs`: A `Map` that contains items.\n  1. `enabled`: A `true` or `false` boolean to specify whether or not the limit_viewable_dirs option is being used.
  If this is set to `false`, then all of the directories listed as the only viewable directories will be ignored, and all directories will be viewable to the user. Default
  is `false`.\n  2. `viewable_dirs`: A `List` that contains all of the directories you would like to be available to users. Note, path needs to be given relative to the
  `root_directory`, and not as absolute paths. E.g., given `root_directory` is "/var/system" and the path you want to specify is "/var/system/test", then
  you would just specify it as "test".\n    2.1 Each entry into the `viewable_dirs` list should be a `Tuple` of the following format: {`directory`, `access`}, where `directory`
  is the directory name (relative to `root_directory` as mentioned above) given as a `String`, and `access` is an atom of either `:rw` or `:ro`.\n
  `username`: The username needed to log into the server. Is \"abc\" by default.\n
  `password`: The password needed to log into the server. Is \"abc\" by default.\n
  `log_file_directory`: The directory where the log file will be stored. Is \"/var/system/priv/log/ftp\" by default.\n
  `debug`: The debug level for logging. Can be either 0, 1 or 2 (default).
          0 -> No debugging at all
          1 -> Will print messages to and from client
          2 -> Will print messages to and from client, and also all debug messages from the server backend.
  """
  def start_server(name, ip, port, root_directory, options \\ []) do
    limit_viewable_dirs = options[:limit_viewable_dirs] || %{enabled: false, viewable_dirs: []}
    username = options[:username] || "abc"
    password = options[:password] || "abc"
    log_file_directory = options[:log_file_directory] || "/var/system/priv/log/ftp"
    debug = options[:debug] || 2
    authentication_function = options[:authentication_function] || nil
    file_handler = options[:file_handler] || Ftp.Permissions

    machine = get_machine_type()

    result =
      pre_run_checks(ip, port, root_directory, limit_viewable_dirs, log_file_directory, machine)

    case result do
      :ok_to_start ->
        ip_address = process_ip(ip)

        Ftp.Supervisor.start_server(
          name,
          ip_address: ip_address,
          port: port,
          root_dir: root_directory,
          username: username,
          password: password,
          log_file_directory: log_file_directory,
          debug: debug,
          machine: machine,
          server_name: name,
          limit_viewable_dirs: limit_viewable_dirs,
          authentication_function: authentication_function,
          file_handler: file_handler
        )

      error ->
        Logger.error("NOT STARTING FTP SERVER '#{name}'. #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Function that runs checks on the arguments passed in before starting the FtpServer. Will return `:ok_to_start` if all tests pass. If not,
  it will return the reason why it can't start as a `String`.


  Examples
      iex> Ftp.pre_run_checks(Ftp.process_ip("127.0.0.1"), 8080, "abc", %{}, "ghi", :nmc3)
      "abc does not exist"
      iex> {:ok, cd} = File.cwd
      iex> not_a_dir = "/bin/sh"
      iex> Ftp.pre_run_checks(Ftp.process_ip("127.0.0.1"), 8080, not_a_dir, %{}, "ghi", :nmc3)
      "/bin/sh exists but it is not a directory"
      iex> Ftp.pre_run_checks(Ftp.process_ip("127.0.0.1"), 8080, cd, %{}, "/usr/abcd", :nmc3)
      "Cannot create log file directory /usr/abcd"
      iex> Ftp.pre_run_checks(Ftp.process_ip("127.0.0.1"), 8080, "/usr", %{}, cd, :nmc3)
      "/usr is part of the RO filesystem"
      iex> Ftp.pre_run_checks(Ftp.process_ip("127.0.0.1"), 8080, cd, %{}, "/usr", :nmc3)
      "/usr is part of the RO filesystem"
      iex> map =  %{enabled: true, viewable_dirs: [{"fw", :rw}, {"waveforms", :ro}]}
      iex> Ftp.pre_run_checks(Ftp.process_ip("127.0.0.1"), 8080, cd, map, cd, :nmc3)
      "Invalid viewable directories listed"

  """
  def pre_run_checks(ip, _port, root_directory, limit_viewable_dirs, log_file_directory, machine) do
    cond do
      File.exists?(root_directory) == false ->
        "#{root_directory} does not exist"

      File.dir?(root_directory) == false ->
        "#{root_directory} exists but it is not a directory"

      machine == :nmc3 && create_log_file_dir(log_file_directory) == false ->
        "Cannot create log file directory #{log_file_directory}"

      machine == :nmc3 && is_read_only_dir(root_directory) == true ->
        "#{root_directory} is part of the RO filesystem"

      machine == :nmc3 && is_read_only_dir(log_file_directory) == true ->
        "#{log_file_directory} is part of the RO filesystem"

      Map.get(limit_viewable_dirs, :enabled) == true &&
          valid_viewable_dirs(root_directory, Map.get(limit_viewable_dirs, :viewable_dirs)) ==
            false ->
        "Invalid viewable directories listed"

      valid_ip?(ip) == false ->
        "'#{ip}' is an invalid IP Address"

      true ->
        :ok_to_start
    end
  end

  @doc """
  Function to convert an IPv4 address given an a `String` to a `Tuple` of integers.

  Examples
      iex> Ftp.process_ip("127.0.0.1")
      {127,0,0,1}
  """
  def process_ip(ip) do
    [h1, h2, h3, h4] = String.split(ip, ".")
    {String.to_integer(h1), String.to_integer(h2), String.to_integer(h3), String.to_integer(h4)}
  end

  @doc """
  Function to validate an IPv4 using a regular expression

  Examples
      iex> Ftp.valid_ip?("127.0.0.1")
      true
      iex> Ftp.valid_ip?("asds")
      false
      iex> Ftp.valid_ip?("127.0.0.1.1")
      false
      iex> Ftp.valid_ip?("127.0.0")
      false
      iex> Ftp.valid_ip?("127.0.0.256")
      false
  """
  def valid_ip?(ip) do
    case :inet.parse_ipv4strict_address(to_charlist(ip)) do
      {:ok, _addr} -> true
      _ -> false
    end
  end

  @doc """
  Function used to create the log file directory
  """
  def create_log_file_dir(path) do
    case File.mkdir(path) do
      :ok ->
        true

      {:error, :eexist} ->
        true

      {:error, reason} ->
        Logger.error("Error creating log file directory. Reason #{inspect(reason)}")
        false
    end
  end

  @doc """
  Function to return the machine type. Still needs work to remove refererces to company
  """
  def get_machine_type() do
    case System.get_env("HOME") do
      "/root" -> :nmc3
      _ -> :desktop
    end
  end

  @doc """
  Function to determine if the `viewable_dirs` are valid and allowed to be used by the Ftp Server
  """
  def valid_viewable_dirs(rootdir, viewable_dirs) do
    Process.put(:valid_view_able_dirs, true)

    for item <- viewable_dirs do
      dir = elem(item, 0)
      path = Path.join([rootdir, dir])

      case File.exists?(path) do
        true ->
          :ok

        false ->
          Logger.error("Viewable dir: #{path} does not exist.")
          Process.put(:valid_view_able_dirs, false)
          :error
      end
    end

    Process.get(:valid_view_able_dirs)
  end

  @doc """
  Function to determine if `path` is read-only or not. If the path is in any way invalid, it is determined as read-only, and this function
  returns `true`
  """
  def is_read_only_dir(path) do
    case File.stat(path) do
      {:ok, info} ->
        case Map.get(info, :access) do
          :read -> true
          :none -> true
          _ -> false
        end

      {:error, _reason} ->
        true
    end
  end

  @doc """
  Runs a sample of the FtpServer
  """
  def sample() do
    # limit_viewable_dirs = %{
    #     enabled: true,
    #     viewable_dirs: [
    #         {"fw", :rw},
    #         {"waveforms", :ro}
    #     ]
    # }
    # start_server("uc1", "127.0.0.1", 2121, "/home/user/var/system/priv/input", limit_viewable_dirs)
    # start_server("uc1", "127.0.0.1", 2121, "/home/user/var/system/priv/input")
    opts = [
      limit_viewable_dirs: %{enabled: false, viewable_dirs: []},
      username: "user",
      password: "pass"
    ]

    root = Path.absname("") <> "/tmp/ftp_root"
    File.mkdir_p!(root)
    start_server(:sample, "127.0.0.1", 2525, root, opts)
  end

  @doc """
  Function to close the server with name `name`. Calling this function will completely close the all GenServers and Supervisors
  """
  def close_server(name) do
    Ftp.Supervisor.stop_server(name)
  end
end
