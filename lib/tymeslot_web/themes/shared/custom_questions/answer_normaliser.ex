defmodule TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliser do
  @moduledoc """
  Wire-protocol coercions for custom-question answers received from the browser.

  LiveView serialises `phx-value-*` attributes to strings, and the note
  checkbox sends the atom-like token `"acknowledge"`. This module normalises
  both cases back to the shapes the Engine validators expect, so every theme
  component shares the same coercion rules.
  """

  @doc """
  Normalises a raw answer value coming from a LiveView event.

  ## Conversions

  - `"true"` → `true`
  - `"false"` → `false`
  - `"acknowledge"` → `%{"confirmed" => true, "confirmed_at" => <ISO8601 UTC>}`
  - anything else → unchanged

  """
  @spec normalise(any()) :: any()
  def normalise("true"), do: true
  def normalise("false"), do: false

  def normalise("acknowledge") do
    %{"confirmed" => true, "confirmed_at" => DateTime.to_iso8601(DateTime.utc_now())}
  end

  def normalise(value), do: value
end
