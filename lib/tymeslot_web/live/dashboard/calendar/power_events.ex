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
  alias TymeslotWeb.Dashboard.Calendar.ReminderFeed

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
  def defaults(socket),
    do: assign(socket, reminder_feed: [], reminder_ref: nil)

  # The `send_update/3` actions of the power layer, which
  # `CalendarSurface.update/2` routes to `update/2`.
  @update_actions [:reminder_tick]

  @doc "The `send_update/3` actions `update/2` answers."
  @spec update_actions() :: [atom()]
  def update_actions, do: @update_actions

  @doc "Applies one of the power layer's `send_update/3` messages."
  @spec update(map(), socket()) :: socket()
  def update(%{action: :reminder_tick, ref: ref}, socket), do: ReminderFeed.tick(socket, ref)
end
