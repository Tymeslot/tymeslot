defmodule TymeslotWeb.Dashboard.Calendar.PowerStrings do
  @moduledoc """
  The client copy of the calendar's power layer (the command bar, the
  shortcut help hint, the search reveal, calendar sets and week numbers),
  merged into `ClientStrings.build/1`. Every string is in the
  `dashboard_calendar_power` domain, and placeholders are bound to
  themselves for the hook to fill, as `ClientStrings` does. Empty until the
  first feature that draws copy in the hook adds its keys.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "The strings map, in the current Gettext locale."
  @spec strings() :: map()
  def strings, do: %{}
end
