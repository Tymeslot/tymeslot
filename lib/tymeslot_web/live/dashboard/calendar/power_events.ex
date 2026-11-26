defmodule TymeslotWeb.Dashboard.Calendar.PowerEvents do
  @moduledoc """
  The one door the calendar surface's power layer comes through: display
  options, the `.ics` import, calendar sets, the command bar and the preview's
  undelivered-update notice.
  `CalendarSurface` routes every event in `events/0` to `handle/3`, which
  hands it to the module `@routes` names; each of those exposes the same
  `handle/3` and parses its params again, ignoring anything else. So does
  `handle/3` itself: the surface's catch-all routes here every event it has
  no clause for, including one of its own sent without the params that clause
  needs, and a stale or crafted client must not take the dashboard down.

  `defaults/1` assigns the power layer's state when the surface mounts.
  """

  import Phoenix.Component, only: [assign: 2]

  alias TymeslotWeb.Dashboard.Calendar.CommandSearch
  alias TymeslotWeb.Dashboard.Calendar.DesktopPermission
  alias TymeslotWeb.Dashboard.Calendar.DisplayPreferences
  alias TymeslotWeb.Dashboard.Calendar.IcsImport
  alias TymeslotWeb.Dashboard.Calendar.ReminderFeed
  alias TymeslotWeb.Dashboard.Calendar.SetEvents
  alias TymeslotWeb.Dashboard.Calendar.UndeliveredNotice

  @type socket :: Phoenix.LiveView.Socket.t()

  @routes %{
    "calendar:set_density" => DisplayPreferences,
    "calendar:toggle_fold_night" => DisplayPreferences,
    "calendar:toggle_weekends" => DisplayPreferences,
    "calendar:toggle_week_numbers" => DisplayPreferences,
    "calendar:set_week_start" => DisplayPreferences,
    "calendar:set_time_format" => DisplayPreferences,
    "calendar:toggle_desktop_reminders" => DisplayPreferences,
    "calendar:desktop_permission" => DesktopPermission,
    "calendar:enable_desktop_reminders" => DesktopPermission,
    "calendar:ics_open" => IcsImport,
    "calendar:ics_close" => IcsImport,
    "calendar:ics_validate" => IcsImport,
    "calendar:ics_cutoff" => IcsImport,
    "calendar:ics_narrow" => IcsImport,
    "calendar:ics_calendar" => IcsImport,
    "calendar:ics_start" => IcsImport,
    "calendar:apply_set" => SetEvents,
    "calendar:edit_set" => SetEvents,
    "calendar:cancel_set_edit" => SetEvents,
    "calendar:save_set" => SetEvents,
    "calendar:delete_set" => SetEvents,
    "calendar:command_query" => CommandSearch,
    "calendar:command_close" => CommandSearch,
    "calendar:dismiss_undelivered" => UndeliveredNotice
  }

  # The power layer's `start_async/3` work: the task's name, then the module
  # whose `async/3` takes its result.
  @async %{ics_import_plan: IcsImport, command_search: CommandSearch}

  @doc "The events `handle/3` answers."
  @spec events() :: [String.t()]
  def events, do: Map.keys(@routes)

  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()} | {:reply, map(), socket()}
  def handle(event, params, socket) do
    case Map.fetch(@routes, event) do
      {:ok, module} -> module.handle(event, params, socket)
      :error -> {:noreply, socket}
    end
  end

  @doc "The `start_async/3` names `async/3` answers."
  @spec async_keys() :: [atom()]
  def async_keys, do: Map.keys(@async)

  @doc """
  Answers the power layer's `start_async/3` work, which
  `CalendarSurface.handle_async/3` routes here.
  """
  @spec async(atom(), term(), socket()) :: {:noreply, socket()}
  def async(key, result, socket), do: Map.fetch!(@async, key).async(key, result, socket)

  @doc "The power layer's assigns, at their defaults."
  @spec defaults(socket()) :: socket()
  def defaults(socket),
    do:
      assign(socket,
        reminder_feed: [],
        reminder_ref: nil,
        desktop_permission: DesktopPermission.initial(),
        ics_import: nil,
        calendar_sets: [],
        active_set: nil,
        manual_hidden_keys: MapSet.new(),
        set_editor: nil,
        command: CommandSearch.empty()
      )

  # The `send_update/3` actions of the power layer, which
  # `CalendarSurface.update/2` routes to `update/2`.
  @update_actions [:reminder_tick, :ics_import_progress, :ics_import_finished]

  @doc "The `send_update/3` actions `update/2` answers."
  @spec update_actions() :: [atom()]
  def update_actions, do: @update_actions

  @doc "Applies one of the power layer's `send_update/3` messages."
  @spec update(map(), socket()) :: socket()
  def update(%{action: :reminder_tick, ref: ref}, socket), do: ReminderFeed.tick(socket, ref)

  # An `.ics` import's progress and end, from `IcsImportRunner`.
  def update(%{action: :ics_import_progress, done: done}, socket),
    do: IcsImport.progress(socket, done)

  def update(%{action: :ics_import_finished, result: result}, socket),
    do: IcsImport.finished(socket, result)
end
