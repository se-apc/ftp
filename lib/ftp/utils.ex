defmodule Ftp.Utils do
    @moduledoc """
    Module for various utility functions
    """

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
end