defmodule TymeslotWeb.Dashboard.Calendar.Navigation do
  @moduledoc """
  How the calendar surface moves between periods: the URL each period lives
  at, and the click that gets there.

  Every navigation control does two things in one click. It dispatches
  `calendar:navigate` to the `CalendarCanvas` hook, which draws the target
  period at once from the events it already holds, and it patches the URL,
  which brings the server's answer for that period. The grid never waits for
  the round trip, and the URL stays the one source of state that reload,
  Back and shared links read.
  """

  use TymeslotWeb, :verified_routes

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.Period

  @canvas "#calendar-canvas"

  @doc "The URL of `view` around `date`."
  @spec path(Period.view(), Date.t()) :: String.t()
  def path(view, date),
    do: ~p"/dashboard/calendar?#{[view: Atom.to_string(view), date: Date.to_iso8601(date)]}"

  @doc "The click that shows `view` around `date`: draw first, then patch."
  @spec js(Period.view(), Date.t()) :: JS.t()
  def js(view, date) do
    "calendar:navigate"
    |> JS.dispatch(
      to: @canvas,
      detail: %{view: Atom.to_string(view), date: Date.to_iso8601(date)}
    )
    |> JS.patch(__MODULE__.path(view, date))
  end
end
