defmodule Ftp.Bifrost do
  @moduledoc """
  Bifrost callbacks
  """
  @behaviour :gen_bifrost_server

  import Ftp.Path

  require Record
  require Logger

  Record.defrecord(
    :file_info,
    Record.extract(:file_info, from: "#{__DIR__}/../../include/bifrost.hrl")
  )

  Record.defrecord(
    :connection_state,
    Record.extract(:connection_state, from: "#{__DIR__}/../../include/bifrost.hrl")
  )

  defmodule State do
    defstruct root_dir: "/",
              current_directory: "/",
              authentication_function: nil,
              expected_username: nil,
              expected_password: nil,
              session: nil,
              user: nil,
              permissions: nil,
              abort_agent: nil,
              offset: 0,
              file_handler: nil,
              server_name: nil
  end

  # State is required to be a record, with our own state nested inside.
  # these are helpers

  def unpack_state(connection_state(module_state: module_state)) do
    module_state
  end

  def pack_state({res, %State{} = module_state}, conn_state) do
    {res, connection_state(conn_state, module_state: module_state)}
  end

  def pack_state(%State{} = module_state, conn_state) do
    connection_state(conn_state, module_state: module_state)
  end

  def pack_state({:ok, send_file, module_state}, conn_state) do
    {:ok, send_file, connection_state(conn_state, module_state: module_state)}
  end

  def pack_state(any, _conn_state) do
    any
  end

  # State, PropList (options) -> State
  def init(connection_state() = init_state, options) do
    init(options)
    |> pack_state(init_state)
  end

  def init(options) do
    permissions =
      if options[:limit_viewable_dirs] do
        %{struct(Ftp.Permissions, options[:limit_viewable_dirs]) | root_dir: options[:root_dir]}
      else
        %Ftp.Permissions{enabled: false, root_dir: options[:root_dir]}
      end

    options =
      options
      |> Keyword.put(:permissions, permissions)
      |> Keyword.put(:expected_username, options[:username])
      |> Keyword.put(:expected_password, options[:password])

    struct(State, options)
  end

  # State, Username, Password -> {true OR false, State}
  def login(connection_state(client_ip_address: ip_address) = conn_state, username, password) do
    conn_state
    |> unpack_state()
    |> login(to_string(username), to_string(password), ip_address)
    |> pack_state(conn_state)
  end

  def login(
        %State{authentication_function: authentication_function} = state,
        username,
        password,
        ip_address
      )
      when is_function(authentication_function, 3) do
    case authentication_function.(username, password, ip_address) do
      {:ok, session, user} ->
        Ftp.EventDispatcher.dispatch(:e_login_successful)
        {true, %{state | session: session, user: user}}

      {:error, error} ->
        Logger.debug("Failed to log in. Reason: #{error}")
        Ftp.EventDispatcher.dispatch(:e_login_failed)
        {false, state}
    end
  end

  def login(
        %State{expected_username: expected_username, expected_password: expected_password} = state,
        username,
        password,
        _ip_address
      ) do
    case {username, password} do
      {^expected_username, ^expected_password} ->
        Ftp.EventDispatcher.dispatch(:e_login_successful)
        {true, %{state | user: expected_username}}

      _ ->
        Ftp.EventDispatcher.dispatch(:e_login_failed)
        {false, state}
    end
  end

  # State -> Path
  def current_directory(connection_state() = conn_state) do
    conn_state
    |> unpack_state()
    |> current_directory()
    |> to_charlist()
  end

  def current_directory(%State{current_directory: current_directory}) do
    current_directory
  end

  # State, Path -> State Change
  def make_directory(connection_state() = conn_state, path) do
    conn_state
    |> unpack_state()
    |> make_directory(to_string(path))
    |> pack_state(conn_state)
  end

  def make_directory(
        %State{current_directory: current_directory, root_dir: root_dir, permissions: permissions} =
          state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    path_exists = File.exists?(working_path)
    have_read_access = allowed_to_read?(permissions, working_path, state)
    have_write_access = allowed_to_write?(permissions, working_path, state)

    cond do
      path_exists == true ->
        {:error, state}

      have_read_access == false || have_write_access == false ->
        {:error, state}

      true ->
        case File.mkdir(working_path) do
          :ok ->
            {:ok, state}

          {:error, _} ->
            {:error, state}
        end
    end
  end

  # State, Path -> State Change
  def change_directory(connection_state() = conn_state, path) do
    conn_state
    |> unpack_state()
    |> change_directory(to_string(path))
    |> pack_state(conn_state)
  end

  def change_directory(
        %State{current_directory: current_directory, root_dir: root_dir, permissions: permissions} =
          state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    Logger.debug("This is working path on server: #{working_path}")

    new_current_directory =
      case String.trim_leading(working_path, root_dir) do
        "" -> "/"
        new_current_directory -> new_current_directory
      end

    path_exists = File.exists?(working_path)
    is_directory = File.dir?(working_path)
    have_read_access = allowed_to_read?(permissions, working_path, state)

    cond do
      is_directory == false ->
        {:error, state}

      path_exists == false ->
        {:error, state}

      have_read_access == false ->
        {:error, state}

      true ->
        {:ok, %{state | current_directory: new_current_directory}}
    end
  end

  # State, Path -> [FileInfo] OR {error, State}
  def list_files(connection_state() = conn_state, path) do
    conn_state
    |> unpack_state()
    |> list_files(to_string(path))
    |> pack_state(conn_state)
  end

  def list_files(
        %State{
          permissions: %{enabled: enabled} = permissions,
          current_directory: current_directory,
          root_dir: root_dir
        } = state,
        args
      ) do
    path =
      args
      |> OptionParser.split()
      |> OptionParser.parse()
      |> case do
        {_parsed, [path], _unknown} -> path
        {_parsed, [], _unknown} -> ""
        _ -> ""
      end

    working_path = determine_path(root_dir, current_directory, path)
    {:ok, files} = File.ls(working_path)

    files =
      case enabled do
        true -> remove_hidden_folders(permissions, working_path, files)
        false -> files
      end

    for file <- files,
        info = encode_file_info(permissions, file |> Path.absname(working_path), state),
        info != nil do
      info
    end
  end

  # State, Path -> State Change
  def remove_directory(connection_state() = conn_state, path) do
    conn_state
    |> unpack_state()
    |> remove_directory(to_string(path))
    |> pack_state(conn_state)
  end

  def remove_directory(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    path_exists = File.exists?(working_path)
    is_directory = File.dir?(working_path)
    have_read_access = allowed_to_read?(permissions, working_path, state)
    have_write_access = allowed_to_write?(permissions, working_path, state)

    cond do
      is_directory == false ->
        {:error, state}

      path_exists == false ->
        {:error, state}

      have_read_access == false || have_write_access == false ->
        {:error, state}

      true ->
        if File.rmdir(working_path) == :ok do
          {:ok, state}
        else
          {:error, state}
        end
    end
  end

  # State, Path -> State Change
  def remove_file(connection_state() = conn_state, path) do
    conn_state
    |> unpack_state()
    |> remove_file(to_string(path))
    |> pack_state(conn_state)
  end

  def remove_file(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)
    path_exists = File.exists?(working_path)
    is_directory = File.dir?(working_path)
    have_read_access = allowed_to_read?(permissions, working_path, state)
    have_write_access = allowed_to_write?(permissions, working_path, state)

    cond do
      is_directory == true ->
        {:error, state}

      path_exists == false ->
        {:error, state}

      have_read_access == false || have_write_access == false ->
        {:error, state}

      true ->
        if File.rm(working_path) == :ok do
          {:ok, state}
        else
          {:error, state}
        end
    end
  end

  # State, File Name, (append OR write), Fun(Byte Count) -> State Change
  def put_file(connection_state() = conn_state, filename, mode, recv_data) do
    conn_state
    |> unpack_state()
    |> put_file(to_string(filename), mode, recv_data)
    |> pack_state(conn_state)
  end

  def put_file(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        filename,
        mode,
        recv_data
      ) do
    working_path = determine_path(root_dir, current_directory, filename)

    if allowed_to_write?(permissions, working_path, state) do
      Logger.debug("working_dir: #{working_path}")

      case File.exists?(working_path) do
        true -> File.rm(working_path)
        false -> :ok
      end

      Ftp.EventDispatcher.dispatch(:e_transfer_started)

      case receive_file(working_path, mode, recv_data) do
        :ok ->
          Ftp.EventDispatcher.dispatch(:e_transfer_successful)
          {:ok, state}

        :error ->
          ## TODO cannot seem to produce this event ##
          Ftp.EventDispatcher.dispatch(:e_transfer_failed)
          {:error, state}
      end
    else
      {:error, state}
    end
  end

  # State, Arg -> State Change
  def abort(connection_state() = conn_state, arg) do
    conn_state
    |> unpack_state()
    |> abort(to_string(arg))
    |> pack_state(conn_state)
  end

  def abort(%State{} = state, _arg) do
    {:ok, set_abort(state, true)}
  end

  # State, Arg -> State Change
  def restart(connection_state() = conn_state, arg) do
    conn_state
    |> unpack_state()
    |> restart(to_string(arg))
    |> pack_state(conn_state)
  end

  def restart(%State{} = state, arg) do
    arg
    |> String.trim()
    |> Integer.parse()
    |> case do
      {offset, _} ->
        {:ok, %{state | offset: offset}}

      _ ->
        :error
    end
  end

  # State, Path -> {ok, Fun(Byte Count)} OR error
  def get_file(connection_state() = conn_state, path) do
    conn_state
    |> unpack_state()
    |> get_file(to_string(path))
    |> pack_state(conn_state)
  end

  def get_file(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)

    path_exists = File.exists?(working_path)
    is_directory = File.dir?(working_path)
    have_read_access = allowed_to_read?(permissions, working_path, state)

    cond do
      is_directory == true ->
        :error

      path_exists == false ->
        :error

      have_read_access == false ->
        :error

      true ->
        {:ok, file} = :file.open(working_path, [:read, :binary])
        :file.position(file, state.offset)
        state = set_abort(%{state | offset: 0}, false)
        Ftp.EventDispatcher.dispatch(:e_transfer_started)
        {:ok, &send_file(state, file, &1), state}
    end
  end

  # State, Path -> {ok, FileInfo} OR {error, ErrorCause}
  def file_information(connection_state() = conn_state, path) do
    conn_state
    |> unpack_state()
    |> file_information(to_string(path))
    |> pack_state(conn_state)
  end

  def file_information(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)

    case encode_file_info(permissions, working_path, state) do
      nil -> {:error, :not_found}
      info -> {:ok, info}
    end
  end

  # State, Path -> {ok, Size} OR {error, ErrorCause}
  def size(connection_state() = conn_state, path) do
    conn_state
    |> unpack_state()
    |> size(to_string(path))
    |> pack_state(conn_state)
  end

  def size(
        %State{
          permissions: permissions,
          root_dir: root_dir,
          current_directory: current_directory
        } = state,
        path
      ) do
    working_path = determine_path(root_dir, current_directory, path)

    case encode_file_info(permissions, working_path, state) do
      nil -> {"-1", state}
      info -> {info |> elem(6) |> to_string(), state}
    end
  end

  # State, From Path, To Path -> State Change
  def rename_file(_state, _from, _to) do
    {:error, :not_supported}
  end

  # State, Command Name String, Command Args String -> State Change
  def site_command(_state, _command, _args) do
    {:error, :not_found}
  end

  # State -> {ok, [HelpInfo]} OR {error, State}
  def site_help(_) do
    {:error, :not_found}
  end

  # State -> State Change
  def disconnect(_state) do
    Ftp.EventDispatcher.dispatch(:e_logout_successful)
    :ok
  end

  #
  # Helpers
  #

  def encode_file_info(permissions, file, state) do
    case File.stat(file) do
      {:ok, %{type: type, mtime: mtime, access: _, size: size}} ->
        type =
          case type do
            :directory -> :dir
            :regular -> :file
          end

        name = Path.basename(file) |> to_charlist()

        mode =
          cond do
            allowed_to_write?(permissions, file, state) ->
              # :read_write
              0o600

            allowed_to_read?(permissions, file, state) ->
              # :read
              0o400
          end

        file_info(
          type: type,
          name: name,
          mode: mode,
          uid: 0,
          gid: 0,
          size: size,
          mtime: mtime
        )

      {:error, _reason} ->
        nil
    end
  end

  def receive_file(to_path, mode, recv_data) do
    case recv_data.() do
      {:ok, bytes, _} ->
        case File.write(to_path, bytes, [mode]) do
          :ok ->
            # Always append after 1st write
            receive_file(to_path, :append, recv_data)

          {:error, _} ->
            :error
        end

      :done ->
        File.write(to_path, <<>>, [mode])
        :ok
    end
  end

  def send_file(state, file, size) do
    unless aborted?(state) do
      case :file.read(file, size) do
        :eof ->
          Ftp.EventDispatcher.dispatch(:e_transfer_successful)
          {:done, state}

        {:ok, bytes} ->
          {:ok, bytes, &send_file(state, file, &1)}

        {:error, _} ->
          Ftp.EventDispatcher.dispatch(:e_transfer_failed)
          {:done, state}
      end
    else
      Ftp.EventDispatcher.dispatch(:e_transfer_failed)
      {:done, state}
    end
  end

  def set_abort(%State{abort_agent: nil} = state, false) do
    {:ok, abort_agent} = Agent.start_link(fn -> false end)
    %{state | abort_agent: abort_agent}
  end

  def set_abort(%State{abort_agent: abort_agent} = state, abort)
      when is_pid(abort_agent) and is_boolean(abort) do
    Agent.update(abort_agent, fn _abort -> abort end)
    state
  end

  def aborted?(%State{abort_agent: abort_agent}) when is_pid(abort_agent) do
    Agent.get(abort_agent, fn abort -> abort end)
  end

  defp allowed_to_read?(permissions, working_path, %State{
         file_handler: file_handler,
         server_name: name
       }) do
    if file_handler == Ftp.Permissions do
      Ftp.Permissions.allowed_to_read?(permissions, working_path)
    else
      file_handler.allowed_to_read?(working_path, name)
    end
  end

  defp allowed_to_write?(permissions, working_path, %State{
         file_handler: file_handler,
         server_name: name
       }) do
    if file_handler == Ftp.Permissions do
      Ftp.Permissions.allowed_to_write?(permissions, working_path)
    else
      file_handler.allowed_to_write?(working_path, name)
    end
  end

  @doc """
  Function to remove the hidden folders from the returned list from `File.ls` command,
  and only show the files specified in the `limit_viewable_dirs` struct.
  """
  def remove_hidden_folders(
        %{root_dir: root_dir, viewable_dirs: viewable_dirs},
        path,
        files
      ) do
    files =
      for file <- files do
        ## prepend the root_dir to each file
        Path.join([path, file])
      end

    viewable_dirs =
      for item <- viewable_dirs do
        file = elem(item, 0)
        ## prepend the root_dir to each viewable path
        Path.join([root_dir, file])
      end

    list =
      for viewable_dir <- viewable_dirs do
        for file <- files do
          case file == String.trim_leading(file, viewable_dir) do
            true ->
              nil

            ## remove the prepended `path` (and `\`) from the file so we can return the original file
            false ->
              String.trim_leading(file, path) |> String.trim_leading("/")
          end
        end
      end

    ## flatten list and remove the `nil` values from the list
    List.flatten(list) |> Enum.filter(fn x -> x != nil end)
  end
end
