defmodule Ftp.Permissions do
  import Ftp.Path
  require Logger

  defstruct root_dir: "",
            enabled: true,
            viewable_dirs: nil

  @doc """
  Simple function to check if the user can view a file/folder. Function attempts to
  perform a `String.trim_leading` call on the `current_path`. If `current_path` is
  part of the `root_path`, the `String.trim_leading` call will be able to remove the
  `root_path` string from the `current_path` string. If not, it will simply return
  the original `current_path`
  """
  def allowed_to_read?(
        %__MODULE__{root_dir: root_dir, viewable_dirs: viewable_dirs, enabled: enabled} =
          permissions,
        current_path
      ) do
    cond do
      is_within_directory(root_dir, current_path) == false ->
        false

      enabled == true && is_within_viewable_dirs(permissions, current_path) == false &&
          current_path != root_dir ->
        false

      true ->
        true
    end
  end

  @doc """
  Function to check if `current_path` is within any of the directories specified
  in the `viewable_dirs` list.
  """
  def is_within_viewable_dirs(
        %__MODULE__{root_dir: root_dir, viewable_dirs: viewable_dirs},
        current_path
      ) do
    list =
    for item <- viewable_dirs do
      dir = elem(item, 0)
      dir = Path.join([root_dir, dir])
      is_within_directory(dir, current_path)
    end
    ## filter out all of the `true` values in the list
    |> Enum.filter(fn x -> x == true end)

    case list do
      ## if no `true` values were returned (i.e. empty list), then `current_path` is not readable
      [] ->
        false

      _ ->
        true
    end
  end

  @doc """
  Function to check if `current_path` is within any of the directories specified
  in the `viewable_dirs` list. Only checks directories with `:rw` permissions
  """
  def is_within_writeable_dirs(
        %__MODULE__{root_dir: root_dir, viewable_dirs: viewable_dirs},
        current_path
      ) do
    list =
    for {dir, access} <- viewable_dirs do
      case access do
        :rw ->
          dir = Path.join([root_dir, dir])
          is_within_directory(dir, current_path)

        :ro ->
          false
      end
    end
    ## filter out all of the `true` values in the list
    |> Enum.filter(fn x -> x == true end)

    case list do
      ## if no `true` values were returned (i.e. empty list), then `current_path` is not writeable
      [] ->
        false

      _ ->
        true
    end
  end

  @doc """
  Function to check if `current_path` is within `root_dir`
  """
  def is_within_directory(root_dir, current_path) do
    if current_path == root_dir do
      true
    else
      case current_path == String.trim_leading(current_path, root_dir) do
        true -> false
        false -> true
      end
    end
  end

  @doc """
  Function used to determine if a user is allowed to write to the `current_path`
  """
  def allowed_to_write?(
        %__MODULE__{root_dir: root_dir, viewable_dirs: _viewable_dirs, enabled: enabled} =
          permissions,
        current_path
      ) do
    parent_dir = Path.dirname(current_path)

    cond do
      is_within_directory(root_dir, current_path) == false -> false
      enabled == true && is_within_writeable_dirs(permissions, current_path) == false -> false
      is_read_only_dir(parent_dir) == true -> false
      true -> true
    end
  end

  @doc """
  Function used to determine if a user is allowed to write a file in the the `file_path`
  """
  def allowed_to_stor?(%__MODULE__{} = permissions, file_path) do
    allowed_to_write?(permissions, Path.dirname(file_path))
  end

  @doc """
  Function to check is `path` is part of the machines own read-only  filesystem
  """
  def is_read_only_dir(path) do
    case File.stat(path) do
      {:ok, info} ->
        case Map.get(info, :access) do
          :read -> true
          :none -> true
          _ -> false
        end

      {:error, error} ->
        Logger.debug(
          "Could not determine if #{inspect(path)} is read-only or not (Reason: #{inspect(error)}), so assuming it is not and returning false."
        )

        false
    end
  end

end
