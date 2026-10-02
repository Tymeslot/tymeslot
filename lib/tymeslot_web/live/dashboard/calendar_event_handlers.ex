defmodule TymeslotWeb.Dashboard.CalendarEventHandlers do
  @moduledoc """
  Handles calendar-related `handle_info/2` messages for `DashboardLive`.

  Each public function accepts the message payload and the socket, returning
  `{:noreply, socket}` so the caller can delegate directly.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [clear_flash: 2, put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Video.RoomCreationError
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCrud
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.IcsImport
  alias TymeslotWeb.Dashboard.CalendarGridComponent

  @doc "Advances the clock-tick timer and pushes the current time to the calendar grid."
  @spec handle_tick(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_tick(socket) do
    if socket.assigns.live_action == :calendar do
      Process.send_after(self(), :tick, 60_000)

      send_update(CalendarGridComponent,
        id: "calendar",
        current_time: DateTime.utc_now()
      )
    end

    {:noreply, socket}
  end

  @doc "Notifies the calendar grid that upstream events have changed."
  @spec handle_calendar_events_updated(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_events_updated(socket) do
    if socket.assigns.live_action == :calendar do
      send_update(CalendarGridComponent,
        id: "calendar",
        action: :events_updated
      )
    end

    {:noreply, socket}
  end

  @doc "Notifies the calendar grid that an integration sync completed."
  @spec handle_calendar_sync_complete(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_sync_complete(socket) do
    if socket.assigns.live_action == :calendar do
      send_update(CalendarGridComponent,
        id: "calendar",
        action: :integration_synced
      )
    end

    {:noreply, socket}
  end

  @doc "Flashes a confirmation after calendar sync."
  @spec handle_calendar_sync_flash(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_sync_flash(socket) do
    {:noreply,
     put_flash(socket, :info, dgettext("dashboard_calendar_events", "Calendars refreshed"))}
  end

  @doc "Tells the calendar grid to refresh its event data."
  @spec handle_reset_calendar_sync(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reset_calendar_sync(socket) do
    if socket.assigns.live_action == :calendar do
      send_update(CalendarGridComponent,
        id: "calendar",
        action: :refresh_events
      )
    end

    {:noreply, socket}
  end

  @doc """
  Handles the result of an event update: on failure, keeps the edit when it
  was queued to sync later and reverts it otherwise. Either way the grid is
  told the write has answered, so the next write to the same event can start
  (see `TymeslotWeb.Dashboard.CalendarGrid.EventWrites`).
  """
  @spec handle_event_update_result(
          {:ok, keyword()} | {:error, keyword()},
          Phoenix.LiveView.Socket.t()
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_update_result({:ok, payload}, socket) do
    settle_write(socket, payload[:write], {:ok, payload[:updated_event]})
    {:noreply, socket}
  end

  def handle_event_update_result({:error, payload}, socket) do
    if payload[:retry] == :queued do
      settle_write(socket, payload[:write], :queued)

      {:noreply,
       put_flash(
         socket,
         :warning,
         dgettext(
           "dashboard_calendar_events",
           "Your calendar could not be reached. The change is saved and will sync on the next attempt."
         )
       )}
    else
      revert_failed_update(payload, socket)
    end
  end

  @doc """
  Hands the grid an event another LiveView's writes have finished with, so
  that the edits it kept for it start (see
  `Tymeslot.CalendarGrid.WriteGuardian`, "A grid mounted in another
  LiveView").
  """
  @spec handle_event_writes_released(tuple(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_writes_released(release, socket) do
    to_grid(socket,
      action: :event_writes_released,
      release: release
    )

    {:noreply, socket}
  end

  # A write's result reaches the grid only while it is on screen. Once the
  # organiser has left the calendar, the LiveView's write guardian drives
  # the queue (`Tymeslot.CalendarGrid.WriteGuardian.detach/0`) and hears
  # every result itself, and a grid component LiveView has yet to delete
  # would otherwise drive the same queue as well, starting its writes a
  # second time.
  defp to_grid(socket, assigns) do
    if socket.assigns.live_action == :calendar,
      do: send_update(CalendarGridComponent, [{:id, "calendar"} | assigns])

    :ok
  end

  defp settle_write(socket, write, outcome) do
    to_grid(socket,
      action: :event_write_settled,
      write: write,
      outcome: outcome
    )
  end

  defp revert_failed_update(payload, socket) do
    to_grid(socket,
      action: :revert_event,
      write: payload[:write],
      original_event: payload[:original_event]
    )

    {:noreply, put_flash(socket, :error, update_failed_message(payload[:reason]))}
  end

  # A refusal the domain made names its own reason; everything else is a
  # provider failure the organiser can do nothing about. The scoped edits of
  # a recurring series refuse before anything is written, so each of their
  # reasons says what the organiser can do instead (see
  # `Tymeslot.CalendarGrid.SeriesEdit`).
  defp update_failed_message(:value_type_change) do
    dgettext(
      "dashboard_calendar_events",
      "Events of a repeating series cannot be switched between all-day and timed here. Please make this change in your calendar app."
    )
  end

  defp update_failed_message(reason) when reason in [:unsupported_scope, :rule_removal] do
    dgettext(
      "dashboard_calendar_events",
      "That change cannot be made to the events you chose. A repeat rule can only be changed for all events, or this and following events, and cannot be removed here."
    )
  end

  defp update_failed_message(:rule_pins_occurrences) do
    dgettext(
      "dashboard_calendar_events",
      "This series repeats on fixed days, such as the second Monday of the month, so it cannot be moved like this. Please make this change in your calendar app."
    )
  end

  defp update_failed_message(:unsupported_rule) do
    dgettext(
      "dashboard_calendar_events",
      "This series' repeat rule cannot be split here. Please make this change in your calendar app."
    )
  end

  defp update_failed_message(:not_organiser), do: EditWorkflow.not_organiser_message()

  defp update_failed_message(reason)
       when reason in [:unaddressable_occurrence, :unreadable_timing, :not_recurring],
       do: EditWorkflow.unmatched_series_message()

  defp update_failed_message(_reason),
    do: dgettext("dashboard_calendar_events", "Failed to update event - changes reverted")

  @doc """
  Handles the result of an event move: shows the moved event and says where
  the original ended up, or reverts the grid when nothing was moved.

  A whole series the organiser confirmed moving (the result carries
  `:series_to`, the destination calendar's name) was never shown moved, so
  nothing is reverted when it fails, and the note that it is moving is
  cleared either way, and the changes held while it moved are made. When
  it succeeds the grid reloads, as
  after any write to a whole series, since the series' rows are gone from
  the source until the destination's sync brings them back.
  """
  @spec handle_event_move_result(
          {:ok, keyword()} | {:error, keyword()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_move_result({:ok, new_event_info}, socket) do
    case new_event_info[:series_to] do
      nil ->
        to_grid(socket,
          action: :event_moved,
          new_event_uid: new_event_info[:uid],
          new_event_integration_id: new_event_info[:integration_id]
        )

        {level, message} = moved_flash(new_event_info[:source])
        {:noreply, put_flash(socket, level, message)}

      calendar ->
        to_grid(socket,
          action: :series_moved,
          moved_event: new_event_info[:original_event]
        )

        {level, message} = series_moved_flash(new_event_info[:source], calendar)
        {:noreply, socket |> clear_flash(:info) |> put_flash(level, message)}
    end
  end

  def handle_event_move_result({:error, payload}, socket) do
    case payload[:series_to] do
      nil ->
        to_grid(socket,
          action: :revert_event,
          original_event: payload[:original_event]
        )

        {:noreply, put_flash(socket, :error, move_failed_message(payload[:reason]))}

      _calendar ->
        to_grid(socket,
          action: :series_move_failed,
          moved_event: payload[:original_event]
        )

        message = EditWorkflow.series_move_failed_message(payload[:reason])
        {:noreply, socket |> clear_flash(:info) |> put_flash(:error, message)}
    end
  end

  defp moved_flash(nil),
    do: {:info, dgettext("dashboard_calendar_events", "Event moved to the new calendar.")}

  defp moved_flash(:queued_delete) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar. The original will be removed on the next sync."
     )}
  end

  defp moved_flash(:left_behind) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar, but the original could not be removed. Please delete it from its original calendar."
     )}
  end

  # Something failed once the new calendar had accepted the event, so it is
  # there, and whether the original is too cannot be said.
  defp moved_flash(:unknown) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar, but the move did not finish. Please check its original calendar and delete the original if it is still there."
     )}
  end

  defp series_moved_flash(nil, calendar) do
    {:info,
     dgettext("dashboard_calendar_events", "The series was moved to %{calendar}.",
       calendar: calendar
     )}
  end

  defp series_moved_flash(:left_behind, calendar) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "The series was copied to %{calendar}, but the original series could not be removed. Please delete it from its original calendar.",
       calendar: calendar
     )}
  end

  defp move_failed_message(:recurring_event), do: EditWorkflow.recurring_move_refused_message()

  defp move_failed_message(_reason) do
    dgettext(
      "dashboard_calendar_events",
      "Could not move the event. It is still on its original calendar."
    )
  end

  @doc "Spawns a supervised task to create a calendar event."
  @spec handle_execute_create_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_create_event(payload, socket) do
    lv_pid = self()

    Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
      send(lv_pid, {:create_event_result, EventCrud.run_create_event(payload)})
    end)

    {:noreply, socket}
  end

  @doc "Delegates the create-event result to `EventCrud`."
  @spec handle_create_event_result(any(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_event_result(result, socket) do
    EventCrud.handle_create_result(result, socket)
  end

  # A send_update re-renders the whole grid, so a long import reports its
  # progress every few events rather than after each one.
  @ics_import_progress_every 10

  @doc """
  Spawns a supervised task that imports an `.ics` plan into a calendar,
  reporting progress and the result back to this LiveView.

  The task is not linked: an import the user walked away from still finishes,
  rather than stopping part-way with some of the file's events written.
  """
  @spec handle_execute_ics_import(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_ics_import(payload, socket) do
    lv_pid = self()
    total = length(payload.plan.events)

    on_progress = fn done ->
      if rem(done, @ics_import_progress_every) == 0 or done == total,
        do: send(lv_pid, {:ics_import_progress, done})
    end

    Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
      result =
        CalendarGrid.import_ics(
          payload.user_id,
          payload.integration_id,
          payload.calendar_id,
          payload.plan,
          on_progress: on_progress
        )

      send(lv_pid, {:ics_import_result, result})
    end)

    {:noreply, socket}
  end

  @doc "Passes a running import's progress to the calendar grid."
  @spec handle_ics_import_progress(non_neg_integer(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_ics_import_progress(done, socket) do
    to_grid(socket, action: :ics_import_progress, done: done)
    {:noreply, socket}
  end

  @doc """
  Hands a finished import to the calendar grid, which closes its modal and
  flashes the outcome; off the calendar page the outcome is flashed here.
  """
  @spec handle_ics_import_result(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_ics_import_result(result, %{assigns: %{live_action: :calendar}} = socket) do
    to_grid(socket, action: :ics_import_finished, result: result)
    {:noreply, socket}
  end

  def handle_ics_import_result(result, socket) do
    {kind, message} = IcsImport.result_flash(result)
    {:noreply, put_flash(socket, kind, message)}
  end

  @doc "Spawns a supervised task to create an ad-hoc meeting."
  @spec handle_execute_create_ad_hoc_meeting(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_create_ad_hoc_meeting(params, socket) do
    lv_pid = self()

    Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
      send(lv_pid, {:create_ad_hoc_meeting_result, EventCrud.run_create_ad_hoc_meeting(params)})
    end)

    {:noreply, socket}
  end

  @doc "Handles the result of an ad-hoc meeting creation."
  @spec handle_create_ad_hoc_meeting_result(
          {:ok, any()} | {:error, String.t()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_ad_hoc_meeting_result({:ok, _result}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :ad_hoc_meeting_created
    )

    {:noreply,
     put_flash(
       socket,
       :info,
       dgettext("dashboard_calendar_events", "Meeting created and invitation sent")
     )}
  end

  def handle_create_ad_hoc_meeting_result({:error, reason}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :ad_hoc_meeting_failed
    )

    {:noreply, put_flash(socket, :error, reason)}
  end

  @doc """
  Handles the result of changing an event's video room: shows the new link,
  or puts the previous choice back and says why nothing changed.

  The change is handed to the grid component as the pair of events it was,
  because only the component owns the "notify attendees?" prompt. The prompt
  is offered from here rather than when the buttons were clicked so that a
  rejected calendar write never tells attendees about a link that was
  discarded.
  """
  @spec handle_event_video_result(
          {:ok | :unchanged | :error, keyword()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_video_result({:unchanged, payload}, socket) do
    settle_write(socket, payload[:write], :unchanged)
    {:noreply, socket}
  end

  def handle_event_video_result({:ok, result}, socket) do
    updated_event = result[:updated_event]

    to_grid(socket,
      action: :video_link_updated,
      write: result[:write],
      original_event: result[:original_event],
      updated_event: updated_event
    )

    {:noreply,
     put_flash(socket, :info, EditWorkflow.video_changed_message(updated_event.video_link))}
  end

  def handle_event_video_result({:error, payload}, socket) do
    to_grid(socket,
      action: :revert_event,
      write: payload[:write],
      original_event: payload[:original_event]
    )

    {:noreply, put_flash(socket, :error, video_failed_message(payload[:reason]))}
  end

  defp video_failed_message(:meet_link_pending) do
    dgettext(
      "dashboard_calendar_events",
      "Google Calendar added Google Meet to the event but has not returned its link yet. Choose Google Meet again to fetch it."
    )
  end

  defp video_failed_message(:linked_to_booking),
    do: EditWorkflow.booking_video_refused_message()

  defp video_failed_message(:missing_meeting_url) do
    dgettext(
      "dashboard_calendar_events",
      "The video provider did not return a meeting link, so the video link was not changed."
    )
  end

  # A provider that refuses to create rooms because of a setting on its own
  # server says which one, and that is what the organiser has to change; the
  # same words their video integration's row shows. Anything else is a failure
  # they can only try again.
  defp video_failed_message({:configuration_error, code}) when is_atom(code) do
    if code in RoomCreationError.codes(),
      do: RoomCreationError.message(code),
      else: video_failed_message(:unknown)
  end

  defp video_failed_message(_reason),
    do:
      dgettext("dashboard_calendar_events", "Could not change the video link - changes reverted")

  @doc """
  Deletes the event `payload` names, in the scope it names, in the background
  through `Tymeslot.CalendarGrid.delete_event/3`, reporting back with
  `{:delete_event_result, result}`.
  """
  @spec handle_execute_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_delete_event(payload, socket) do
    socket
    |> EditWorkflow.run_async(
      :delete_event_result,
      fn ->
        CalendarGrid.delete_event(payload.user_id, payload, payload.scope,
          notify_attendees: payload.notify_on_delete
        )
      end,
      {:error, %{reason: :crashed, retry: :not_queued}}
    )
    |> assign(:pending_delete, Map.take(payload, [:notify_on_delete, :scope]))
    |> then(&{:noreply, &1})
  end

  @doc "Delegates the delete-event result to `EventCrud`."
  @spec handle_delete_event_result(any(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete_event_result(result, socket) do
    EventCrud.handle_delete_result(result, socket)
  end
end
