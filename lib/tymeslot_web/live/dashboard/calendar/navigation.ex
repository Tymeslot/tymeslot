defmodule TymeslotWeb.Dashboard.Calendar.Navigation do
  @moduledoc """
  How the calendar surface moves between periods: the URL each period lives
  at, and the click that gets there.

  Every navigation control does two things in one click. It patches the URL,
  which brings the server's answer for that period, and it dispatches
  `calendar:navigate` to the `CalendarCanvas` hook, which draws the target
  period at once from the events it already holds. The grid never waits for
  the round trip, and the URL stays the one source of state that reload,
  Back and shared links read.

  The patch goes first. A step control (previous, next) also tells the hook
  its `step`: a second click before the server has re-rendered still carries
  the target the first click saw, so the hook steps from the target it is
  already heading for and asks the server for the period beyond with
  `calendar:goto`, which then arrives after the stale patch and wins.
  """

  use TymeslotWeb, :verified_routes

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.Period

  @canvas "#calendar-canvas"

  @doc "The URL of `view` around `date`."
  @spec path(Period.view(), Date.t()) :: String.t()
  def path(view, date),
    do: ~p"/dashboard/calendar?#{[view: Atom.to_string(view), date: Date.to_iso8601(date)]}"

  @doc """
  The click that shows `view` around `date`: patch, then draw. Pass `step:`
  (-1 or 1) for a control that moves by one period.
  """
  @spec js(Period.view(), Date.t(), keyword()) :: struct()
  def js(view, date, opts \\ []) do
    detail =
      Map.merge(
        %{view: Atom.to_string(view), date: Date.to_iso8601(date)},
        Map.new(Keyword.take(opts, [:step]))
      )

    # `__MODULE__.` because `path/2` alone is the verified-routes macro.
    __MODULE__.path(view, date)
    |> JS.patch()
    |> JS.dispatch("calendar:navigate", to: @canvas, detail: detail)
  end
end
