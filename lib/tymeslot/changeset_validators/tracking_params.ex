defmodule Tymeslot.ChangesetValidators.TrackingParams do
  @moduledoc """
  Shared changeset validator bounding a client-supplied `tracking_params` map.

  Both `Tymeslot.Meetings.MeetingSchema` and `Tymeslot.Analytics.EventSchema`
  persist UTM/tracking maps that originate from untrusted query strings. This
  enforces the same key-count, byte-size and string-type bounds at the data
  layer for every caller, so the web-side `UtmExtractor` is not the only guard.
  """

  import Ecto.Changeset

  @max_keys 16
  @max_value_bytes 255

  @spec validate_tracking_params(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_tracking_params(changeset, field) do
    validate_change(changeset, field, fn ^field, params -> validate_map(field, params) end)
  end

  defp validate_map(field, params) when map_size(params) > @max_keys do
    [{field, "must have at most #{@max_keys} keys"}]
  end

  defp validate_map(field, params) do
    Enum.reduce_while(params, [], fn {key, value}, _acc ->
      cond do
        not is_binary(key) ->
          {:halt, [{field, "keys must be strings"}]}

        not is_binary(value) ->
          {:halt, [{field, "values must be strings"}]}

        byte_size(key) > @max_value_bytes ->
          {:halt, [{field, "keys must be at most #{@max_value_bytes} bytes"}]}

        byte_size(value) > @max_value_bytes ->
          {:halt, [{field, "values must be at most #{@max_value_bytes} bytes"}]}

        true ->
          {:cont, []}
      end
    end)
  end
end
