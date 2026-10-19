defmodule TymeslotWeb.Dashboard.Calendar.PowerEvents do
  @moduledoc """
  The one door the calendar surface's power layer comes through: display
  options, and later the `.ics` import, calendar sets and the command bar.
  `CalendarSurface` routes every event in `events/0` to `handle/3`, which
  hands it to the module `@routes` names; each of those exposes the same
  `handle/3` and parses its params again, ignoring anything else.

  `defaults/1` assigns the power layer's state when the surface mounts.
  """

  import Phoenix.Component, only: [assign: 2]

  alias TymeslotWeb.Dashboard.Calendar.DisplayPreferences

  @type socket :: Phoenix.LiveView.Socket.t()

  @routes %{
    "calendar:set_density" => DisplayPreferences,
    "calendar:toggle_fold_night" => DisplayPreferences,
    "calendar:toggle_weekends" => DisplayPreferences,
    "calendar:toggle_week_numbers" => DisplayPreferences,
    "calendar:set_week_start" => DisplayPreferences,
    "calendar:set_time_format" => DisplayPreferences,
    "calendar:toggle_desktop_reminders" => DisplayPreferences
  }

  @doc "The events `handle/3` answers."
  @spec events() :: [String.t()]
  def events, do: Map.keys(@routes)

  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()} | {:reply, map(), socket()}
  def handle(event, params, socket), do: Map.fetch!(@routes, event).handle(event, params, socket)

  @doc "The power layer's assigns, at their defaults."
  @spec defaults(socket()) :: socket()
  # Tasks 6, 8, 11 and 14 replace the empty list with their assigns (see
  # the plan 6 contracts).
  def defaults(socket), do: assign(socket, [])
end
