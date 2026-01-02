defmodule Tymeslot.Utils.ChangesetUtils do
  @moduledoc """
  Utility functions for working with Ecto changesets.
  """

  alias Ecto.Changeset

  @doc """
  Formats changeset errors into a human-readable string.

  ## Examples

      iex> format_errors(changeset)
      "email: can't be blank; name: should be at least 3 characters"
  """
  @spec format_errors(Changeset.t()) :: String.t()
  def format_errors(changeset) do
    formatted =
      Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts
          |> Keyword.get(String.to_existing_atom(key), key)
          |> to_string()
        end)
      end)

    Enum.map_join(formatted, "; ", fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
  end

  @doc """
  Gets the first error message from a changeset.

  ## Examples

      iex> get_first_error(changeset)
      "Email can't be blank"
  """
  @spec get_first_error(Changeset.t()) :: String.t() | nil
  def get_first_error(changeset) do
    case Changeset.traverse_errors(changeset, &translate_error/1) do
      errors when map_size(errors) > 0 ->
        {field, [message | _]} = Enum.at(errors, 0)
        "#{humanize(field)} #{message}"

      _ ->
        nil
    end
  end

  @doc """
  Extracts all error messages as a list.

  ## Examples

      iex> get_error_list(changeset)
      ["Email can't be blank", "Name should be at least 3 characters"]
  """
  @spec get_error_list(Changeset.t()) :: [String.t()]
  def get_error_list(changeset) do
    errors = Changeset.traverse_errors(changeset, &translate_error/1)

    Enum.flat_map(errors, fn {field, messages} ->
      Enum.map(messages, fn msg -> "#{humanize(field)} #{msg}" end)
    end)
  end

  # Private functions

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      to_string(Keyword.get(opts, String.to_existing_atom(key), key))
    end)
  end

  defp humanize(atom) do
    atom
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
