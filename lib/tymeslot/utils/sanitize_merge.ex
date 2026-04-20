defmodule Tymeslot.Utils.SanitizeMerge do
  @moduledoc """
  Safe merging of sanitiser / derived-data output back into user-submitted
  params.

  A bare `Map.merge(params, sanitized)` can silently overwrite a valid
  user-provided value when the right-hand side carries a "no value here"
  sentinel for a field:

    * `nil` — returned by optional-field validators (e.g.
      `validate_calendar_integration_id(nil, _) → {:ok, nil}`).
    * `[]` — returned by selection helpers when zero items are selected
      (e.g. `prepare_selection_params([], _) → %{"calendar_paths" => []}`).

  `merge/2` preserves the user-provided value in those two cases, so a
  cleared optional field or an empty selection list cannot wipe out a
  populated params entry.

  An empty string (`""`) is deliberately **not** treated as a drop signal:
  content-stripping sanitisers (HTML removal, etc.) return `""` to clear
  malicious input, and that overwrite must still land. In the common
  happy-path case where both sides are blank strings, the merge simply
  writes the sanitised `""` through — identical to `Map.merge/2` behaviour.
  """

  @type params :: map()

  @doc """
  Merges `sanitized` into `params`, dropping `nil` or `[]` sanitised values
  that would overwrite a populated user-provided field.
  """
  @spec merge(params(), params()) :: params()
  def merge(params, sanitized) when is_map(params) and is_map(sanitized) do
    Enum.reduce(sanitized, params, fn {key, sanitized_value}, acc ->
      if drop?(sanitized_value, Map.get(acc, key)) do
        acc
      else
        Map.put(acc, key, sanitized_value)
      end
    end)
  end

  defp drop?(nil, params_value), do: not blank?(params_value)
  defp drop?([], params_value), do: not blank?(params_value)
  defp drop?(_sanitized, _params_value), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_other), do: false
end
