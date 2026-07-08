defmodule TymeslotWeb.OnboardingLive.TextHelpers do
  @moduledoc """
  Shared text-formatting helpers for the onboarding flow.

  Functions that produce human-readable labels for scheduling values.
  Extracted from the individual step and preview components so both surfaces
  render identical, grammatical copy for the same value.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Returns a human-readable string for a number of days.

  Covers all preset and edge-case values used across onboarding steps and the
  live-preview component. The `nil` clause delegates to the 90-day default so
  callers do not need to guard before formatting.
  """
  @spec humanize_days(non_neg_integer() | nil) :: String.t()
  def humanize_days(nil), do: humanize_days(90)

  def humanize_days(1),
    do: dngettext("onboarding_wizard", "%{count} day", "%{count} days", 1, count: 1)

  def humanize_days(7),
    do: dngettext("onboarding_wizard", "%{count} week", "%{count} weeks", 1, count: 1)

  def humanize_days(14),
    do: dngettext("onboarding_wizard", "%{count} week", "%{count} weeks", 2, count: 2)

  def humanize_days(30),
    do: dngettext("onboarding_wizard", "%{count} month", "%{count} months", 1, count: 1)

  def humanize_days(60),
    do: dngettext("onboarding_wizard", "%{count} month", "%{count} months", 2, count: 2)

  def humanize_days(90),
    do: dngettext("onboarding_wizard", "%{count} month", "%{count} months", 3, count: 3)

  def humanize_days(180),
    do: dngettext("onboarding_wizard", "%{count} month", "%{count} months", 6, count: 6)

  def humanize_days(365),
    do: dngettext("onboarding_wizard", "%{count} year", "%{count} years", 1, count: 1)

  def humanize_days(days),
    do: dngettext("onboarding_wizard", "%{count} day", "%{count} days", days, count: days)
end
