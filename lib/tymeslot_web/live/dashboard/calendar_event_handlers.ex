defmodule TymeslotWeb.Dashboard.CalendarEventHandlers do
  @moduledoc """
  Handles calendar-related `handle_info/2` messages for `DashboardLive`.

  Each public function accepts the message payload and the socket, returning
  `{:noreply, socket}` so the caller can delegate directly.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView, only: [clear_flash: 2, put_flash: 3]

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.CalendarGrid.WriteTask
  alias Tymeslot.Integrations.Video.RoomCreationError
  alias TymeslotWeb.Dashboard.CalendarEditMessages
  alias TymeslotWeb.Dashboard.CalendarRouting
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage

  @doc "Notifies the calendar on screen that upstream events have changed."
  @spec handle_calendar_events_updated(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_events_updated(socket) do
    CalendarRouting.refresh(socket, :events_updated)

    {:noreply, socket}
  end

  @doc "Tells the calendar on screen that `integration_id`'s sync completed."
  @spec handle_calendar_sync_complete(Phoenix.LiveView.Socket.t(), integer()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_sync_complete(socket, integration_id) do
    CalendarRouting.refresh(socket, :integration_synced, integration_id: integration_id)

    {:noreply, socket}
  end

  @doc "Tells the calendar on screen that `integration_id`'s sync failed or was discarded."
  @spec handle_calendar_sync_failed(Phoenix.LiveView.Socket.t(), integer()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_sync_failed(socket, integration_id) do
    CalendarRouting.sync_failed(socket, integration_id)

    {:noreply, socket}
  end

  @doc "Tells the calendar how a delete it scheduled ended."
  @spec handle_calendar_delete_result(Phoenix.LiveView.Socket.t(), pos_integer(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_delete_result(socket, token, outcome) do
    CalendarRouting.delete_settled(socket, token, outcome)

    {:noreply, socket}
  end

  @doc """
  Handles the result of an event update: on failure, keeps the edit when it
  was queued to sync later and reverts it otherwise. Either way the calendar
  is told the write has answered, so the next write to the same event can
  start (see `TymeslotWeb.Dashboard.Calendar.Writes`).
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
      {:noreply, queued_flash(socket)}
    else
      revert_failed_update(payload, socket)
    end
  end

  # The calendar says this in its sync banner, naming the change.
  defp queued_flash(socket) do
    if CalendarRouting.surface_on_screen?(socket),
      do: socket,
      else:
        put_flash(
          socket,
          :warning,
          dgettext(
            "dashboard_calendar_events",
            "Your calendar could not be reached. The change is saved and will sync on the next attempt."
          )
        )
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
    CalendarRouting.to_mounted(socket,
      action: :event_writes_released,
      release: release
    )

    {:noreply, socket}
  end

  defp settle_write(socket, write, outcome) do
    CalendarRouting.to_mounted(socket,
      action: :event_write_settled,
      write: write,
      outcome: outcome
    )
  end

  defp revert_failed_update(payload, socket) do
    CalendarRouting.to_mounted(socket,
      action: :revert_event,
      write: payload[:write],
      original_event: payload[:original_event]
    )

    # The inline edit announces its save up front, before the write runs.
    {:noreply,
     socket |> clear_flash(:info) |> put_flash(:error, update_failed_message(payload[:reason]))}
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

  # What is left of a count is counted again when the change is written, from
  # the series as it is then, which a sync may have changed since the scope
  # was chosen. The prompt offered that scope, so these say the series moved
  # on under the organiser rather than repeating why a scope is not offered.
  defp update_failed_message(:ends_before) do
    dgettext(
      "dashboard_calendar_events",
      "This series changed while you were editing it, and nothing is left of it from this event on. Nothing was saved."
    )
  end

  # Either the series' first start can no longer be read, or a sync cleared
  # its rule while it is still marked a series: both leave nothing to count
  # from.
  defp update_failed_message(:start_unknown) do
    dgettext(
      "dashboard_calendar_events",
      "This series changed while you were editing it, so the events left in it can no longer be counted. Nothing was saved. Refresh the calendar and try again."
    )
  end

  defp update_failed_message(:rule_not_supported_by_outlook),
    do: CalendarEditMessages.rule_not_supported_by_outlook_message()

  defp update_failed_message(:day_missing_in_some_months),
    do: CalendarEditMessages.month_end_refused_message()

  defp update_failed_message(:not_organiser), do: CalendarEditMessages.not_organiser_message()

  defp update_failed_message(reason)
       when reason in [:unaddressable_occurrence, :unreadable_timing, :not_recurring],
       do: CalendarEditMessages.unmatched_series_message()

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

  While the calendar is on screen a successful move is named by the
  surface's toast instead of a flash.
  """
  @spec handle_event_move_result(
          {:ok, keyword()} | {:error, keyword()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_move_result({:ok, new_event_info}, socket) do
    source = new_event_info[:source]

    case new_event_info[:series_to] do
      nil ->
        CalendarRouting.to_mounted(socket,
          action: :event_moved,
          new_event_uid: new_event_info[:uid],
          new_event_integration_id: new_event_info[:integration_id],
          original_event: new_event_info[:original_event],
          source: source
        )

        {:noreply, result_flash(socket, CalendarEditMessages.moved_message(source))}

      calendar ->
        CalendarRouting.to_mounted(socket,
          action: :series_moved,
          moved_event: new_event_info[:original_event],
          source: source
        )

        {:noreply,
         socket
         |> clear_flash(:info)
         |> result_flash(CalendarEditMessages.series_moved_message(source, calendar))}
    end
  end

  def handle_event_move_result({:error, payload}, socket) do
    case payload[:series_to] do
      nil ->
        CalendarRouting.to_mounted(socket,
          action: :revert_event,
          original_event: payload[:original_event]
        )

        {:noreply,
         put_flash(socket, :error, CalendarEditMessages.move_failed_message(payload[:reason]))}

      _calendar ->
        CalendarRouting.to_mounted(socket,
          action: :series_move_failed,
          moved_event: payload[:original_event]
        )

        message = CalendarEditMessages.series_move_failed_message(payload[:reason])
        {:noreply, socket |> clear_flash(:info) |> put_flash(:error, message)}
    end
  end

  # The calendar names a change's result itself (a move in its toast,
  # with Undo when it can be taken back; a video change in the panel's
  # header), so a flash beside it would say it twice.
  defp result_flash(socket, {level, message}) do
    if CalendarRouting.surface_on_screen?(socket),
      do: socket,
      else: put_flash(socket, level, message)
  end

  @doc """
  Handles the result of changing an event's video room: shows the new link,
  or puts the previous choice back and says why nothing changed.

  The change is handed to the calendar as the pair of events it was,
  because only the calendar owns the "notify attendees?" prompt. The prompt
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

    CalendarRouting.to_mounted(socket,
      action: :video_link_updated,
      write: result[:write],
      original_event: result[:original_event],
      updated_event: updated_event
    )

    {:noreply,
     result_flash(
       socket,
       {:info, CalendarEditMessages.video_changed_message(updated_event.video_link)}
     )}
  end

  def handle_event_video_result({:error, payload}, socket) do
    CalendarRouting.to_mounted(socket,
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
    do: CalendarEditMessages.booking_video_refused_message()

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
  Creates a Tymeslot meeting with guests in the background, through
  `Tymeslot.CalendarGrid.EventCreation.run_create_ad_hoc_meeting/1`, and
  reports back with `{:create_ad_hoc_meeting_result, request, result}`, where
  `result` is `{:error, :crashed}` if the create raises (`WriteTask`). The
  calendar that offers meeting mode sends
  `{:execute_create_ad_hoc_meeting, request, params}`; `request` is its ref
  for the panel that asked, handed back so only that panel acts on the result.
  """
  @spec handle_execute_create_ad_hoc_meeting(reference(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_execute_create_ad_hoc_meeting(request, params, socket) do
    :ok =
      WriteTask.start(
        {:create_ad_hoc_meeting_result, request},
        fn -> EventCreation.run_create_ad_hoc_meeting(params) end,
        {:error, :crashed}
      )

    {:noreply, socket}
  end

  @doc """
  Handles the result of the meeting `request`: the organiser is told how it
  went, and the calendar on screen hears `:ad_hoc_meeting_created` or
  `:ad_hoc_meeting_failed` with the request, so the panel that asked for it
  can close or reopen its form.
  """
  @spec handle_create_ad_hoc_meeting_result(
          reference(),
          {:ok, any()} | {:error, term()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_ad_hoc_meeting_result(request, {:ok, _result}, socket) do
    CalendarRouting.to_mounted(socket, action: :ad_hoc_meeting_created, request: request)

    {:noreply,
     put_flash(
       socket,
       :info,
       dgettext("dashboard_calendar_events", "Meeting created and invitation sent")
     )}
  end

  def handle_create_ad_hoc_meeting_result(request, {:error, reason}, socket) do
    CalendarRouting.to_mounted(socket, action: :ad_hoc_meeting_failed, request: request)
    {:noreply, put_flash(socket, :error, ad_hoc_failed_message(reason))}
  end

  # The reason is a domain term, never copy: an atom such as `:time_conflict`
  # would otherwise reach the flash verbatim. `CreateAdHoc`'s own refusals are
  # atoms `BookingErrorMessage` renders, and anything it does not recognise
  # falls back to a generic sentence there. A conflict may be with a booking
  # the host cannot see (one awaiting its attendee's email verification or
  # payment), so it never claims a meeting is there.
  defp ad_hoc_failed_message(:time_conflict) do
    dgettext(
      "dashboard_calendar_events",
      "This time is no longer available. Please choose another time."
    )
  end

  # A saved location deleted after the panel built the meeting, before the
  # booking read it.
  defp ad_hoc_failed_message(:invalid_location) do
    dgettext(
      "dashboard_calendar_events",
      "That location can no longer be used. Please choose another one."
    )
  end

  defp ad_hoc_failed_message(reason), do: BookingErrorMessage.message(reason)
end
