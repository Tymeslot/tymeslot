defmodule TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliser do
  @moduledoc """
  Wire-protocol coercions for custom-question answers received from the browser.

  LiveView serialises `phx-value-*` attributes to strings, and the note
  checkbox sends the atom-like token `"acknowledge"`. This module normalises
  both cases back to the shapes the Engine validators expect, so every theme
  component shares the same coercion rules.
  """

  @doc """
  Normalises a raw answer value coming from a LiveView event for a given
  question `type`.

  Coercion is type-aware: the wire tokens are only meaningful for the
  question types that emit them, so a booker who literally types `"true"`,
  `"false"` or `"acknowledge"` into a text/phone/url question keeps that
  verbatim string. Without this, those words were silently rewritten to a
  boolean/map and then rejected by the text validator.

  ## Conversions

  - `yes_no`: `"true"` → `true`, `"false"` → `false`
  - `note`: `"acknowledge"` → `%{"confirmed" => true, "confirmed_at" => <ISO8601 UTC>}`
  - everything else (including text answers that happen to read like a token)
    → unchanged

  """
  @spec normalise(any(), String.t() | nil) :: any()
  def normalise(value, type \\ nil)

  def normalise("true", "yes_no"), do: true
  def normalise("false", "yes_no"), do: false

  def normalise("acknowledge", "note") do
    %{"confirmed" => true, "confirmed_at" => DateTime.to_iso8601(DateTime.utc_now())}
  end

  def normalise(value, _type), do: value
end
