defmodule Tymeslot.Integrations.Video.AttrsCasting do
  @moduledoc """
  Converts video integration attribute maps to atom-keyed maps for casting.
  """

  require Logger

  @doc """
  Converts string keys to atoms, dropping any key with no existing atom
  rather than retaining it as a string — a mixed atom/string map raises
  `Ecto.CastError` on cast. Shared by `Video.create_integration/3` and the
  video edit form so the two callers cannot diverge on this.
  """
  @spec atomize_known_attrs(%{(String.t() | atom()) => term()}) :: %{atom() => term()}
  def atomize_known_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {k, v}, acc when is_binary(k) ->
        try do
          Map.put(acc, String.to_existing_atom(k), v)
        rescue
          error in ArgumentError ->
            Logger.warning("Dropping unrecognised video integration attribute",
              attribute: k,
              error: Exception.message(error)
            )

            acc
        end

      {k, v}, acc when is_atom(k) ->
        Map.put(acc, k, v)
    end)
  end
end
