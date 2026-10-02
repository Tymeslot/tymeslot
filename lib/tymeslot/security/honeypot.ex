defmodule Tymeslot.Security.Honeypot do
  @moduledoc """
  The honeypot every public form carries: a text field humans never see and
  bots fill in along with everything else.

  One field name and one rule for every form, so a form cannot end up with a
  field the server never checks, or a check that reads a field the form never
  renders. The field is drawn by
  `TymeslotWeb.Components.CoreComponents.honeypot_field/1`.

  A tripped honeypot is answered with the same success the form shows a human,
  never with an error: telling the bot the truth would let it learn to skip
  the field. Each caller logs the hit as a security event of its own.
  """

  @field "website"

  @doc """
  The name of the honeypot input, under the form's param root if it has one.
  """
  @spec field() :: String.t()
  def field, do: @field

  @doc """
  Whether a submission filled in the honeypot.

  `params` is the form's own params map (the one holding the honeypot key).
  Any non-empty string counts, whitespace included: a human never types into a
  field they cannot see, so even a space is a bot.
  """
  @spec tripped?(map()) :: boolean()
  def tripped?(%{@field => value}) when is_binary(value), do: value != ""
  def tripped?(params) when is_map(params), do: false
end
