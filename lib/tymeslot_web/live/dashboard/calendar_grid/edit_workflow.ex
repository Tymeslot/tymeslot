defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow do
  @moduledoc "Drag, resize, create, and inline-edit workflow orchestration for CalendarGridComponent."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.RecurrenceScope
  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.EventWrites
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  require Logger

  @spec default_integration_id(Phoenix.LiveView.Socket.t()) :: integer() | nil
  def default_integration_id(socket) do
    # The first connection that can actually take an event. Taking the first of
    # all of them pre-selected read-only ones — a subscribed ICS feed sorting
    # ahead of a writable account left the form pointing at a calendar whose
    # provider answers `{:error, :read_only}`.
    case Calendar.writable_integrations(socket.assigns.integrations) do
      [first | _rest] -> first.id
      [] -> nil
    end
  end

  @spec default_calendar_id(list(), integer() | nil) :: String.t() | nil
  def default_calendar_id(_integrations, nil), do: nil

  def default_calendar_id(integrations, integration_id) do
    case Enum.find(integrations, &(&1.id == integration_id)) do
      nil -> nil
      integration -> default_calendar_id_for(integration)
    end
  end

  @doc """
  Resolves the calendar to pre-select for `integration`, restricted to the
  same subset `CalendarPicker` renders as chips (`Calendar.writable_calendars/1`
  — selected and not read-only). Resolving against a wider set here than the
  picker offers would default to a calendar the user is never shown, and the
  event would be created there with no chip highlighted to explain it.
  """
  @spec default_calendar_id_for(map()) :: String.t() | nil
  def default_calendar_id_for(integration) do
    booking_id = Map.get(integration, :default_booking_calendar_id)
    calendars = Calendar.writable_calendars(integration.calendar_list)

    case Calendar.default_booking_calendar(calendars, booking_id) do
      nil -> nil
      entry -> entry.id
    end
  end

  @spec format_time_value(integer(), integer()) :: String.t()
  def format_time_value(hour, minute) do
    "#{String.pad_leading("#{hour}", 2, "0")}:#{String.pad_leading("#{minute}", 2, "0")}"
  end

  @spec with_editable_event(Phoenix.LiveView.Socket.t(), map(), function()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def with_editable_event(socket, params, fun) do
    case Integer.parse(params["event-id"] || "") do
      {event_id, ""} ->
        case Enum.find(socket.assigns.events, &(&1.id == event_id)) do
          nil -> {:noreply, socket}
          event -> with_editable_event_found(socket, event, fun)
        end

      _invalid ->
        {:noreply, socket}
    end
  end

  defp with_editable_event_found(socket, event, fun) do
    case assert_event_writable(socket, event) do
      :ok -> {:noreply, fun.(event)}
      {:error, _reason} = error -> Shared.flash_guard_error(socket, error)
    end
  end

  @doc """
  Applies a new start and end to `event`: optimistically on screen, then
  either through the recurrence prompt (see `series_edit?/1`) or straight to
  the provider.

  Whether to tell the attendees is decided once the provider has accepted
  the write, in the scope the organiser chose (see `EventWrites`): asked
  before, the organiser could be told attendees will be notified of a
  change that then failed, was cancelled at the recurrence prompt, or went
  to a whole series whose cached rows the debounced notification reads.

  `opts` takes `:saved_message`, what the organiser is told once the change
  is saved with nobody to notify; without it nothing is said (a drag).
  """
  @spec apply_event_change(
          Phoenix.LiveView.Socket.t(),
          map(),
          map(),
          DateTime.t(),
          DateTime.t(),
          keyword()
        ) :: Phoenix.LiveView.Socket.t()
  def apply_event_change(socket, event, optimistic_event, new_start, new_end, opts \\ []) do
    new_events = Shared.replace_event(socket.assigns.events, event.id, optimistic_event)
    notify = %{original: event, saved_message: Keyword.get(opts, :saved_message)}

    socket =
      socket
      |> assign(:events, new_events)
      |> Helpers.precompute_derived()

    if series_edit?(event) do
      prompt = %{
        event: event,
        optimistic_event: optimistic_event,
        new_start: new_start,
        new_end: new_end,
        original_event: event,
        notify: notify
      }

      assign(socket, :recurrence_prompt, prompt)
    else
      update_event_async(socket, event, %{start_at: new_start, end_at: new_end}, notify: notify)
    end
  end

  @doc """
  Whether an edit of `event` asks the organiser which occurrences of its
  series it applies to: this event, this and following, or all of them.

  Only a member of a series whose provider can write each of those scopes is
  asked (`Tymeslot.CalendarGrid.edit_scopes/1` answers `:series`): Google,
  Outlook and the CalDAV family. An event outside a series, and a member of a
  series whose provider writes only the one event (Exchange), are written
  straight away, as that one event.
  """
  @spec series_edit?(map()) :: boolean()
  def series_edit?(event), do: CalendarGrid.edit_scopes(event) == {:ok, :series}

  @doc """
  Runs `fun` in a supervised Task and sends `{tag, result}` back to this
  LiveView process once it returns.

  If `fun` raises, throws or exits, `{tag, crash_result}` is sent instead, so
  the handler for `tag` still hears back and an optimistic update on screen is
  never left standing without an answer.

  With `report_to_guardian: true` in `opts`, `{tag, result}` goes first to
  this LiveView's `Tymeslot.CalendarGrid.WriteGuardian`, looked up once
  `fun` returns, which finishes the grid's queued writes should this
  LiveView, or its grid, be gone by then.
  """
  @spec run_async(Phoenix.LiveView.Socket.t(), atom(), (-> term()), term(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def run_async(socket, tag, fun, crash_result, opts \\ [])
      when is_atom(tag) and is_function(fun, 0) do
    lv_pid = self()
    report_to_guardian? = Keyword.get(opts, :report_to_guardian, false)

    {:ok, _pid} =
      Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
        message = {tag, run_guarded(tag, fun, crash_result)}

        if report_to_guardian?,
          do: WriteGuardian.report(lv_pid, message),
          else: send(lv_pid, message)
      end)

    socket
  end

  defp run_guarded(tag, fun, crash_result) do
    fun.()
  catch
    kind, reason ->
      Logger.error("Calendar grid task crashed",
        task: tag,
        kind: kind,
        error: LogFormat.reason(reason),
        stacktrace: LogFormat.stacktrace(__STACKTRACE__)
      )

      crash_result
  end

  @doc """
  Writes `changes` to `event` in the background through
  `Tymeslot.CalendarGrid.update_event/4`, after any write to the same event
  still in flight. See `TymeslotWeb.Dashboard.CalendarGrid.EventWrites`, which
  also describes the `{:event_update_result, result}` message it answers with.

  `opts` are passed through to `CalendarGrid.update_event/4`, except
  `:notify`: `%{original: event, saved_message: message}` runs the
  attendee-notification decision (`apply_notify_result/5`) once the write
  succeeds, diffing the event it wrote against `original`.
  """
  @spec update_event_async(Phoenix.LiveView.Socket.t(), map(), map(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def update_event_async(socket, event, changes, opts \\ []),
    do: EventWrites.update(socket, event, changes, opts)

  @doc """
  Gives `event` a room on the video integration `video_integration_id`, or
  removes its video link when that is `nil`, in the background through
  `Tymeslot.CalendarGrid.change_event_video/3`, after any write to the same
  event still in flight.

  Reports back with `{:event_video_result, result}`; a successful change
  carries the updated event, with the new link, its integration and the
  description the calendar was given, so the result handler can diff it
  against the original for the attendee-notification decision. See
  `TymeslotWeb.Dashboard.CalendarGrid.EventWrites`.
  """
  @spec change_event_video_async(Phoenix.LiveView.Socket.t(), map(), pos_integer() | nil) ::
          Phoenix.LiveView.Socket.t()
  def change_event_video_async(socket, event, video_integration_id),
    do: EventWrites.change_video(socket, event, video_integration_id)

  @doc "The message shown once an event's video room has been changed."
  @spec video_changed_message(String.t() | nil) :: String.t()
  def video_changed_message(nil),
    do: dgettext("dashboard_calendar_events", "Video link removed.")

  def video_changed_message(_url),
    do: dgettext("dashboard_calendar_events", "Video room created.")

  @doc """
  Moves `event` to `integration` (on `calendar_id`, or its default calendar
  when `nil`) in the background through `Tymeslot.CalendarGrid.move_event/3`.

  Reports back with `{:event_move_result, {:ok, uid: uid, integration_id: id,
  source: source, original_event: event}}`, where `source` is `nil` when the
  original was removed, `:queued_delete` or `:left_behind` otherwise; or with
  `{:event_move_result, {:error, original_event: event, reason: reason}}`
  when nothing was moved.

  `opts` takes `:series_to`, the name of the destination calendar, for the
  move of a whole series the organiser has confirmed; both answers then
  carry it, so the result handler can tell a series move from the move of
  one event.
  """
  @spec move_event_async(Phoenix.LiveView.Socket.t(), map(), map(), String.t() | nil, keyword()) ::
          Phoenix.LiveView.Socket.t()
  def move_event_async(socket, event, integration, calendar_id, opts \\ []) do
    user_id = socket.assigns.current_user.id
    destination = %{integration: integration, calendar_id: calendar_id}
    series = Keyword.take(opts, [:series_to])

    run_async(
      socket,
      :event_move_result,
      fn ->
        case CalendarGrid.move_event(user_id, event, destination) do
          {:ok, moved} ->
            {:ok,
             [
               uid: moved.uid,
               integration_id: moved.integration_id,
               source: moved[:source],
               original_event: event
             ] ++ series}

          {:error, reason} ->
            move_failure(event, reason, series)
        end
      end,
      move_failure(event, :crashed, series),
      # A whole-series move holds the series' other writes until it
      # answers (see `EventWrites.series_moving/2`), so its answer goes to
      # their guardian too.
      report_to_guardian: series != []
    )
  end

  defp move_failure(event, reason, series),
    do: {:error, [original_event: event, reason: reason] ++ series}

  @doc """
  The message shown when an organiser tries to move a recurring event whose
  calendar provider cannot move a whole series (Exchange).
  """
  @spec recurring_move_refused_message() :: String.t()
  def recurring_move_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "Recurring events on this calendar cannot be moved to another calendar. Only single events can be moved."
    )
  end

  @doc "The message shown when an organiser has moved events too often in a short while."
  @spec move_rate_limited_message() :: String.t()
  def move_rate_limited_message,
    do: dgettext("dashboard_calendar_events", "Too many moves. Please wait a moment.")

  @doc """
  The message shown when a recurring series could not be moved, for each
  reason `Tymeslot.CalendarGrid.move_event/3` and
  `Tymeslot.CalendarGrid.series_move_notes/2` give. Every one of them means
  the series is still where it was.
  """
  @spec series_move_failed_message(term()) :: String.t()
  def series_move_failed_message(:recurring_event), do: recurring_move_refused_message()

  def series_move_failed_message(:cross_provider_series) do
    dgettext(
      "dashboard_calendar_events",
      "A recurring event can only be moved to a calendar of the same kind of account: Google to Google, Outlook to Outlook, or CalDAV to CalDAV."
    )
  end

  def series_move_failed_message(reason)
      when reason in [:unaddressable_series, :not_recurring, :unreadable_timing],
      do: unmatched_series_message()

  def series_move_failed_message(:not_organiser), do: not_organiser_message()

  def series_move_failed_message(:same_calendar),
    do: dgettext("dashboard_calendar_events", "The series is already on that calendar.")

  def series_move_failed_message(:no_destination_calendar) do
    dgettext(
      "dashboard_calendar_events",
      "That calendar cannot be written to. Please choose another calendar."
    )
  end

  def series_move_failed_message(_reason) do
    dgettext(
      "dashboard_calendar_events",
      "Could not move the series. It is still on its original calendar."
    )
  end

  @doc """
  The message shown when a write to a series is refused because someone
  else organises it: moving or splitting a series re-creates it, which only
  its organiser may do.
  """
  @spec not_organiser_message() :: String.t()
  def not_organiser_message do
    dgettext(
      "dashboard_calendar_events",
      "Someone else organises this meeting, so Tymeslot can't move or split a series you were only invited to."
    )
  end

  @doc """
  The message shown when the grid cannot tell which series, or which
  occurrence of it, an event is.
  """
  @spec unmatched_series_message() :: String.t()
  def unmatched_series_message do
    dgettext(
      "dashboard_calendar_events",
      "This event could not be matched to its series. Refresh your calendars and try again."
    )
  end

  @doc """
  The message shown when an organiser tries to change the video of an event
  that is the calendar copy of a booking.
  """
  @spec booking_video_refused_message() :: String.t()
  def booking_video_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "This event is a booking, so its video link belongs to the booking. Reschedule or cancel the booking to change it."
    )
  end

  @spec assert_owns_event(Phoenix.LiveView.Socket.t(), map()) :: :ok | {:error, :unauthorized}
  def assert_owns_event(socket, event) do
    assert_owns_integration(socket, event.calendar_integration_id)
  end

  @doc """
  The gate every write to an existing grid event goes through: the organiser
  must own the integration *and* the calendar the event sits on must accept
  writes.

  Ownership alone is not enough. A subscribed feed is the organiser's own
  integration, yet every provider write against it answers
  `{:error, :read_only}`; a Google calendar shared with `reader` access is
  likewise owned and unwritable. Refusing here is what keeps the failure a
  clear message instead of a provider round-trip that ends in "Failed to
  delete event".

  `event_editable?/2` is the same question asked of the assigns, and gates the
  affordance in the detail modal. The two must agree: this one is the
  authority, since a stale socket can still send the event.
  """
  @spec assert_event_writable(Phoenix.LiveView.Socket.t(), map()) ::
          :ok | {:error, :unauthorized} | {:error, :read_only}
  def assert_event_writable(socket, event) do
    with :ok <- assert_owns_event(socket, event) do
      if writable_event?(socket.assigns, event), do: :ok, else: {:error, :read_only}
    end
  end

  @doc """
  Whether the detail modal should offer edit and delete controls for `event`.

  Takes the assigns rather than the socket so templates can call it directly.
  """
  @spec event_editable?(map(), map()) :: boolean()
  def event_editable?(assigns, event) do
    MapSet.member?(assigns.owned_integration_ids, event.calendar_integration_id) and
      writable_event?(assigns, event)
  end

  # Resolves the event's integration from the loaded list — the same list
  # `owned_integration_ids` is built from, so an event whose integration is
  # missing here is one the organiser does not own.
  defp writable_event?(assigns, event) do
    case Enum.find(assigns.integrations, &(&1.id == event.calendar_integration_id)) do
      nil -> false
      integration -> Selection.event_writable?(event, integration)
    end
  end

  @spec assert_owns_integration(Phoenix.LiveView.Socket.t(), integer() | nil) ::
          :ok | {:error, :unauthorized}
  def assert_owns_integration(socket, integration_id) do
    if MapSet.member?(socket.assigns.owned_integration_ids, integration_id) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Routes an event edit through `Tymeslot.Meetings.AttendeeNotifications`.

  Returns one of:

    * `{:ok, :no_changes}` — nothing notifiable changed, or the event has no
      attendees. Caller should flash "Changes saved."
    * `{:ok, :already_pending}` — changes were notifiable, but a Worker job is
      already queued inside the debounce window. This call re-confirmed into
      the existing job (replacing `scheduled_at`). Caller should flash
      "Changes saved. Attendees will be notified shortly."
    * `{:needs_confirmation, ChangeSummary.t}` — notifiable changes, nothing
      pending. Caller should stash the summary and show the confirmation modal.
  """
  @spec notify_event_updated(map(), map(), [map()], RecurrenceScope.t()) ::
          {:ok, :no_changes}
          | {:ok, :already_pending}
          | {:needs_confirmation, ChangeSummary.t()}
  def notify_event_updated(original_event, updated_event, attendees, scope \\ :this_only) do
    case AttendeeNotifications.event_updated(original_event, updated_event, attendees) do
      {:ok, :no_changes} ->
        {:ok, :no_changes}

      # Sent at once, never joined to a debounced job: see
      # `AttendeeNotifications.series_updated_confirm/4`.
      {:needs_confirmation, summary} when scope in [:following, :all] ->
        {:needs_confirmation, summary}

      {:needs_confirmation, summary} ->
        if AttendeeNotifications.pending?(updated_event) do
          {:ok, :sent} =
            AttendeeNotifications.event_updated_confirm(updated_event, summary, attendees)

          {:ok, :already_pending}
        else
          {:needs_confirmation, summary}
        end
    end
  end

  @doc """
  Acts on the `notify_event_updated/4` decision for an edit that has already
  been applied: flashes `saved_message`, joins a pending notification, or
  stashes the summary so the component renders the "notify attendees?" prompt.

  Every inline edit ends here, so the prompt cannot be skipped for one field
  and offered for another. `saved_message` is what the organiser is told when
  there is nobody to notify, or `nil` to say nothing; the video path passes
  its own wording rather than the generic one.

  `scope` is the recurrence scope the edit was written in. The prompt for an
  edit of this and every following occurrence, or of all of them, carries
  it and the event as it was, since confirming it sends the update at once
  from both (`AttendeeNotifications.series_updated_confirm/4`).
  """
  @spec apply_notify_result(
          Phoenix.LiveView.Socket.t(),
          map(),
          map(),
          String.t() | nil,
          RecurrenceScope.t()
        ) :: Phoenix.LiveView.Socket.t()
  def apply_notify_result(
        socket,
        original_event,
        updated_event,
        saved_message \\ changes_saved(),
        scope \\ :this_only
      ) do
    attendees = updated_event.attendees || original_event.attendees || []

    case notify_event_updated(original_event, updated_event, attendees, scope) do
      {:ok, :no_changes} ->
        if saved_message, do: send(self(), {:flash, {:info, saved_message}})
        socket

      {:ok, :already_pending} ->
        send(
          self(),
          {:flash,
           {:info,
            dgettext(
              "dashboard_calendar_events",
              "Changes saved. Attendees will be notified shortly."
            )}}
        )

        assign(socket, :pending_notification, true)

      {:needs_confirmation, summary} ->
        assign(socket, :notify_prompt, %{
          kind: :update,
          summary: summary,
          event: updated_event,
          original_event: original_event,
          attendees: attendees,
          scope: scope
        })
    end
  end

  defp changes_saved, do: dgettext("dashboard_calendar_events", "Changes saved.")
end
