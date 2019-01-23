defmodule Ftp.Utils do
    @moduledoc """
    Module for various utility functions
    """

    @doc """
    Fuction to return `true` or `false` when a table with name `name` of type `Atom`
    exists or not.
    """
    def ets_table_exists?(name) when is_atom(name) do
        case :ets.whereis(name) do
          :undefined -> false
          _tid -> true
        end
    end
end