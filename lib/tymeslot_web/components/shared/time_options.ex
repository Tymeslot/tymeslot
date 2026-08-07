defmodule TymeslotWeb.Components.Shared.TimeOptions do
  @moduledoc """
  Shared helpers for time-related UI options used across dashboard components.
  """

  use Phoenix.Component

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

  @doc """
  Returns 15-minute interval options as `{label, value}` pairs.

  The **value** is always 24h `HH:MM`: it is what the form submits and what
  `Tymeslot.Availability` parses, so it must not vary with what the organiser
  is looking at. Only the **label** follows their clock preference, so a 12-hour
  organiser picks "2:30 PM" from the list and the schedule still stores 14:30.
  """
  @spec time_options(String.t() | nil) :: list({String.t(), String.t()})
  def time_options(time_format \\ "24h") do
    for hour <- 0..23, minute <- [0, 15, 30, 45] do
      value =
        String.pad_leading("#{hour}", 2, "0") <> ":" <> String.pad_leading("#{minute}", 2, "0")

      {TimeFormat.format(Time.new!(hour, minute, 0), time_format), value}
    end
  end
end
