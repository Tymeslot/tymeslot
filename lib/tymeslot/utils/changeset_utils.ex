defmodule Tymeslot.Utils.ChangesetUtils do
  @moduledoc """
  Utility functions for working with Ecto changesets.
  """

  alias Ecto.Changeset

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
        # Sort keys to ensure deterministic "first" error message
        first_field = errors |> Map.keys() |> Enum.sort() |> List.first()
        message = errors |> Map.get(first_field, []) |> List.first()
        "#{humanize(first_field)} #{message}"

      _other ->
        nil
    end
  end

  # Private functions

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _arg1, key ->
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
