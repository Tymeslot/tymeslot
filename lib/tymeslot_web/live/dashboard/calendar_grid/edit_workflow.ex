defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow do
  @moduledoc "Drag, resize, create, and inline-edit workflow orchestration for CalendarGridComponent."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  require Logger

  @spec default_integration_id(Phoenix.LiveView.Socket.t()) :: integer() | nil
  def default_integration_id(socket) do
    case socket.assigns.integrations do
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
    case assert_event_editable(socket, event) do
      :ok -> {:noreply, fun.(event)}
      {:error, _reason} = error -> Shared.flash_guard_error(socket, error)
    end
  end

  @doc """
  Applies a new start and end to `event`: optimistically on screen, then
  either through the recurrence prompt or straight to the provider.

  An edit the provider can only write to a whole series is refused here,
  before the optimistic update and before the prompt. The prompt offers "this
  event only", so putting it in front of a write that moves every occurrence
  would be the bug with a dialog on top of it; see
  `Tymeslot.CalendarGrid.EventEdit.ensure_editable/1`. The gate the handlers
  call, and the domain itself, refuse the same edit again — this clause is
  what keeps the prompt out of a path either of them somehow let through.
  """
  @spec apply_event_change(Phoenix.LiveView.Socket.t(), map(), map(), DateTime.t(), DateTime.t()) ::
          Phoenix.LiveView.Socket.t()
  def apply_event_change(socket, event, optimistic_event, new_start, new_end) do
    case CalendarGrid.ensure_editable(event) do
      :ok -> reschedule(socket, event, optimistic_event, new_start, new_end)
      {:error, :recurring_event} -> refuse_recurring_edit(socket)
    end
  end

  @doc """
  Flashes the refusal for an edit that would change a whole series and leaves
  `socket` untouched, so nothing optimistic is left on screen.
  """
  @spec refuse_recurring_edit(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refuse_recurring_edit(socket) do
    send(self(), {:flash, {:error, recurring_edit_refused_message()}})
    socket
  end

  @doc "The message shown when an organiser tries to edit a recurring event."
  @spec recurring_edit_refused_message() :: String.t()
  def recurring_edit_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "Recurring events cannot be edited here yet. Please change this one in your calendar app."
    )
  end

  defp reschedule(socket, event, optimistic_event, new_start, new_end) do
    new_events = Shared.replace_event(socket.assigns.events, event.id, optimistic_event)

    socket =
      socket
      |> assign(:events, new_events)
      |> Helpers.precompute_derived()

    if event.recurring_event_id do
      prompt = %{
        event: event,
        optimistic_event: optimistic_event,
        new_start: new_start,
        new_end: new_end,
        original_event: event
      }

      assign(socket, :recurrence_prompt, prompt)
    else
      update_event_async(socket, event, %{start_at: new_start, end_at: new_end})
    end
  end

  @doc """
  Runs `fun` in a supervised Task and sends `{tag, result}` back to this
  LiveView process once it returns.

  If `fun` raises, throws or exits, `{tag, crash_result}` is sent instead, so
  the handler for `tag` still hears back and an optimistic update on screen is
  never left standing without an answer.
  """
  @spec run_async(Phoenix.LiveView.Socket.t(), atom(), (-> term()), term()) ::
          Phoenix.LiveView.Socket.t()
  def run_async(socket, tag, fun, crash_result) when is_atom(tag) and is_function(fun, 0) do
    lv_pid = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
        send(lv_pid, {tag, run_guarded(tag, fun, crash_result)})
      end)

    socket
  end

  defp run_guarded(tag, fun, crash_result) do
    fun.()
  catch
    kind, reason ->
      Logger.error("Calendar grid task crashed",
        task: tag,
        error: Exception.format(kind, reason, __STACKTRACE__)
      )

      crash_result
  end

  @doc """
  Writes `changes` to `event` in the background through
  `Tymeslot.CalendarGrid.update_event/4` and reports back with
  `{:event_update_result, :ok}` or `{:event_update_result, {:error, payload}}`,
  where `payload` carries `:original_event`, `:reason` and `:retry`
  (`:queued` when the edit is saved locally and will sync, `:not_queued`
  otherwise).

  `opts` are passed through to `CalendarGrid.update_event/4`.
  """
  @spec update_event_async(Phoenix.LiveView.Socket.t(), map(), map(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def update_event_async(socket, event, changes, opts \\ []) do
    user_id = socket.assigns.current_user.id

    run_async(
      socket,
      :event_update_result,
      fn ->
        case CalendarGrid.update_event(user_id, event, changes, opts) do
          {:ok, _updated} -> :ok
          {:error, %{reason: reason, retry: retry}} -> update_failure(event, reason, retry)
        end
      end,
      update_failure(event, :crashed, :not_queued)
    )
  end

  defp update_failure(event, reason, retry),
    do: {:error, original_event: event, reason: reason, retry: retry}

  @doc """
  Gives `event` a room on the video integration `video_integration_id`, or
  removes its video link when that is `nil`, in the background through
  `Tymeslot.CalendarGrid.change_event_video/3`.

  Reports back with `{:event_video_result, {:ok, original_event: event,
  updated_event: event}}`, where the updated event carries the new link, its
  integration and the description the calendar was given, so the result
  handler can diff the two for the attendee-notification decision. A choice
  that changed nothing reports `{:event_video_result, {:ok, :unchanged}}`, and
  a failure `{:event_video_result, {:error, original_event: event, reason:
  reason}}`.
  """
  @spec change_event_video_async(Phoenix.LiveView.Socket.t(), map(), pos_integer() | nil) ::
          Phoenix.LiveView.Socket.t()
  def change_event_video_async(socket, event, video_integration_id) do
    user_id = socket.assigns.current_user.id

    run_async(
      socket,
      :event_video_result,
      fn ->
        case CalendarGrid.change_event_video(user_id, event, video_integration_id) do
          {:ok, :unchanged} ->
            {:ok, :unchanged}

          {:ok, url} ->
            {:ok,
             original_event: event,
             updated_event: video_changed_event(event, video_integration_id, url)}

          {:error, reason} ->
            video_failure(event, reason)
        end
      end,
      video_failure(event, :crashed)
    )
  end

  # The event as `EventVideo` has just written it: the same description
  # rewrite it sent to the calendar, so the notification diff sees exactly
  # what the attendees' invitation will carry.
  defp video_changed_event(event, video_integration_id, url) do
    %{
      event
      | video_integration_id: video_integration_id,
        video_link: url,
        description: CalendarGrid.put_join_link(event.description, event.video_link, url)
    }
  end

  defp video_failure(event, reason), do: {:error, original_event: event, reason: reason}

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
  source: source}}`, where `source` is `nil` when the original was removed,
  `:queued_delete` or `:left_behind` otherwise; or with
  `{:event_move_result, {:error, original_event: event, reason: reason}}`
  when nothing was moved.
  """
  @spec move_event_async(Phoenix.LiveView.Socket.t(), map(), map(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def move_event_async(socket, event, integration, calendar_id) do
    user_id = socket.assigns.current_user.id
    destination = %{integration: integration, calendar_id: calendar_id}

    run_async(
      socket,
      :event_move_result,
      fn ->
        case CalendarGrid.move_event(user_id, event, destination) do
          {:ok, moved} ->
            {:ok, uid: moved.uid, integration_id: moved.integration_id, source: moved[:source]}

          {:error, reason} ->
            move_failure(event, reason)
        end
      end,
      move_failure(event, :crashed)
    )
  end

  defp move_failure(event, reason), do: {:error, original_event: event, reason: reason}

  @doc "The message shown when an organiser tries to move a recurring event."
  @spec recurring_move_refused_message() :: String.t()
  def recurring_move_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "Recurring events cannot be moved to another calendar yet. Only single events can be moved."
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
  The gate every edit of an existing grid event goes through: it must pass
  `assert_event_writable/2`, and it must not be an occurrence of a series the
  provider can only write as a whole.

  The second half is `Tymeslot.CalendarGrid.ensure_editable/1`, and it is
  deliberately not folded into `assert_event_writable/2`: a delete asks the
  narrower question (see `EventHandlers.EventDelete`, which pairs that gate
  with `ensure_deletable/1` instead), and `event_editable?/2` must keep
  agreeing with the writability half alone.
  """
  @spec assert_event_editable(Phoenix.LiveView.Socket.t(), map()) ::
          :ok | {:error, :unauthorized | :read_only | :recurring_event}
  def assert_event_editable(socket, event) do
    with :ok <- assert_event_writable(socket, event) do
      CalendarGrid.ensure_editable(event)
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
  @spec notify_event_updated(map(), map(), [map()]) ::
          {:ok, :no_changes}
          | {:ok, :already_pending}
          | {:needs_confirmation, ChangeSummary.t()}
  def notify_event_updated(original_event, updated_event, attendees) do
    case AttendeeNotifications.event_updated(original_event, updated_event, attendees) do
      {:ok, :no_changes} ->
        {:ok, :no_changes}

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
  Acts on the `notify_event_updated/3` decision for an edit that has already
  been applied: flashes `saved_message`, joins a pending notification, or
  stashes the summary so the component renders the "notify attendees?" prompt.

  Every inline edit ends here, so the prompt cannot be skipped for one field
  and offered for another. `saved_message` is what the organiser is told when
  there is nobody to notify; the video path passes its own wording rather
  than the generic one.
  """
  @spec apply_notify_result(Phoenix.LiveView.Socket.t(), map(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def apply_notify_result(socket, original_event, updated_event, saved_message \\ changes_saved()) do
    attendees = updated_event.attendees || original_event.attendees || []

    case notify_event_updated(original_event, updated_event, attendees) do
      {:ok, :no_changes} ->
        send(self(), {:flash, {:info, saved_message}})
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
          attendees: attendees
        })
    end
  end

  defp changes_saved, do: dgettext("dashboard_calendar_events", "Changes saved.")
end
