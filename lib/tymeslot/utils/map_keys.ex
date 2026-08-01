defmodule Tymeslot.Utils.MapKeys do
  @moduledoc """
  Reads a field from a map that may be atom-keyed or string-keyed,
  depending on where it came from (built in code vs. round-tripped through
  JSON, form params, or a JSONB column).

  Only for genuinely context-free reads, where the caller supplies the key
  and no other domain knowledge is involved. A field whose name or shape is
  specific to one producer (e.g. a fixed list of known keys normalised at a
  schema boundary) should normalise there instead of calling this per read;
  see `Tymeslot.Integrations.Calendar.CalendarEntry.normalize/1` for that
  pattern.
  """

  @doc """
  Reads `key` from `map`, trying the atom key first and falling back to its
  string form.

  ## Examples

      iex> Tymeslot.Utils.MapKeys.get(%{email: "a@example.com"}, :email)
      "a@example.com"

      iex> Tymeslot.Utils.MapKeys.get(%{"email" => "a@example.com"}, :email)
      "a@example.com"

      iex> Tymeslot.Utils.MapKeys.get(%{}, :email)
      nil
  """
  @spec get(map(), atom()) :: term()
  def get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  @doc """
  Like `get/2`, but only returns the value when it is a binary; any other
  value (including a non-map `map`) returns `nil`. Useful for an optional
  string field that must not be conflated with a present-but-non-string
  value.

  ## Examples

      iex> Tymeslot.Utils.MapKeys.get_binary(%{"uid" => "abc"}, :uid)
      "abc"

      iex> Tymeslot.Utils.MapKeys.get_binary("abc", :uid)
      nil
  """
  @spec get_binary(term(), atom()) :: String.t() | nil
  def get_binary(map, key) when is_map(map) and is_atom(key) do
    case get(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  def get_binary(_map, _key), do: nil
end
