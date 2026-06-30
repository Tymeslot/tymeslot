defmodule TymeslotWeb.OnboardingLive.TextHelpers do
  @moduledoc """
  Shared text-formatting helpers for the onboarding flow.

  Functions that produce human-readable labels for scheduling values.
  Extracted from the individual step and preview components so both surfaces
  render identical, grammatical copy for the same value.
  """

  @doc """
  Returns a human-readable string for a number of days.

  Covers all preset and edge-case values used across onboarding steps and the
  live-preview component. The `nil` clause delegates to the 90-day default so
  callers do not need to guard before formatting.
  """
  @spec humanize_days(non_neg_integer() | nil) :: String.t()
  def humanize_days(nil), do: humanize_days(90)
  def humanize_days(1), do: "1 day"
  def humanize_days(7), do: "1 week"
  def humanize_days(14), do: "2 weeks"
  def humanize_days(30), do: "1 month"
  def humanize_days(60), do: "2 months"
  def humanize_days(90), do: "3 months"
  def humanize_days(180), do: "6 months"
  def humanize_days(365), do: "1 year"
  def humanize_days(days), do: "#{days} days"
end
