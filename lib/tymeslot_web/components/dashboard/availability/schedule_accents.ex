defmodule TymeslotWeb.Components.Dashboard.Availability.ScheduleAccents do
  @moduledoc """
  The colour each availability schedule is drawn in.

  Every schedule holds the same shape of data, so colour is what tells them
  apart at a glance: the availability page paints a schedule's tab, panel frame
  and background with its hue, and the meeting-type form marks its chip with the
  same one, so a host recognises "the amber schedule" across both.

  Assigned by position in the profile's schedule list, which both callers get
  from `Tymeslot.Availability.Schedules.list_for_profile/1` and therefore see in
  the same order. The list is as long as the schedule cap; `rem/2` keeps
  `at/1` total should that cap ever rise.
  """

  @accents [
    %{
      panel: "border-turquoise-300 bg-turquoise-50 shadow-turquoise-500/20",
      bar: "bg-turquoise-100 border-turquoise-300",
      tab: "bg-turquoise-600 text-white shadow-lg shadow-turquoise-500/30",
      dot: "bg-turquoise-500"
    },
    %{
      panel: "border-violet-300 bg-violet-50 shadow-violet-500/20",
      bar: "bg-violet-100 border-violet-300",
      tab: "bg-violet-600 text-white shadow-lg shadow-violet-500/30",
      dot: "bg-violet-500"
    },
    %{
      panel: "border-amber-300 bg-amber-50 shadow-amber-500/20",
      bar: "bg-amber-100 border-amber-300",
      tab: "bg-amber-600 text-white shadow-lg shadow-amber-500/30",
      dot: "bg-amber-500"
    },
    %{
      panel: "border-emerald-300 bg-emerald-50 shadow-emerald-500/20",
      bar: "bg-emerald-100 border-emerald-300",
      tab: "bg-emerald-600 text-white shadow-lg shadow-emerald-500/30",
      dot: "bg-emerald-500"
    },
    %{
      panel: "border-blue-300 bg-blue-50 shadow-blue-500/20",
      bar: "bg-blue-100 border-blue-300",
      tab: "bg-blue-600 text-white shadow-lg shadow-blue-500/30",
      dot: "bg-blue-500"
    }
  ]

  @doc "The accent at a position in the schedule list."
  @spec at(non_neg_integer()) :: map()
  def at(index), do: Enum.at(@accents, rem(index, length(@accents)))

  @doc """
  The accent belonging to `schedule` within `schedules`.

  Falls back to the first accent for a schedule that is missing or not in the
  list, so a page with nothing selected still has a colour rather than no
  styling at all.
  """
  @spec for_schedule([map()], map() | nil) :: map()
  def for_schedule(_schedules, nil), do: at(0)

  def for_schedule(schedules, %{id: id}) do
    schedules
    |> Enum.find_index(&(&1.id == id))
    |> Kernel.||(0)
    |> at()
  end
end
