defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared do
  @moduledoc "Shared helpers used across EventHandlers submodules."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.Recurrence.Series
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.Calendar.ReminderForm
  alias TymeslotWeb.Components.Calendar.RepeatForm
  alias TymeslotWeb.Dashboard.CalendarEditMessages
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec parse_int(binary()) :: {:ok, integer()} | :error
  @spec parse_int(term()) :: :error
  def parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  def parse_int(_not_binary), do: :error

  # Normalises an incoming colour-picker value to a stored colour. A recognised
  # palette key passes through unchanged; the "default" sentinel, an empty
  # string, or any unrecognised value clears the override (`nil`).
  @spec parse_colour(term()) :: String.t() | nil
  def parse_colour(value) do
    if EventColour.valid_key?(value), do: value, else: nil
  end

  # Constructs a UTC DateTime from a date and time in the user's display timezone.
  # The calendar grid renders events in the user's timezone, so drag/drop/create
  # coordinates are in that timezone and must be converted back to UTC for storage.
  #
  # DST gaps and overlaps resolve by `DateTimeUtils.resolve_local/3`, the rule
  # every other wall-clock conversion uses. An unknown timezone is returned as
  # `{:error, reason}` so callers can surface a flash instead of crashing the
  # LiveView.
  @spec to_utc(Date.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def to_utc(date, hour, minute, timezone) do
    time = Time.new!(hour, minute, 0, {0, 6})

    with {:ok, local} <- DateTimeUtils.resolve_local(date, time, timezone) do
      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    end
  end

  @spec clamp_end_time(Date.t(), non_neg_integer(), non_neg_integer()) ::
          {Date.t(), non_neg_integer(), non_neg_integer()}
  def clamp_end_time(date, hour, minute) when hour >= 24 do
    {Date.add(date, 1), 0, minute}
  end

  def clamp_end_time(date, hour, minute), do: {date, hour, minute}

  @spec check_edit_rate_limit(Phoenix.LiveView.Socket.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_edit_rate_limit(socket), do: EditGuard.rate_limit(socket.assigns.current_user.id)

  @doc """
  Refuses a change to a calendar event that a group meeting with live seats
  sits on: moving or resizing it, changing its recurrence, deleting it, or
  adding or removing its attendees.

  The organiser's provider event is a projection of the Tymeslot meeting, not
  the meeting itself. Moving it does not move the participants' seats (their
  reschedule links still point at the booked slot, and the next sync reports
  the organiser's own edit back as an external change); deleting it leaves
  everyone booked on a meeting with no calendar event; and its attendee list
  is not who holds a seat. The grid hides these controls on a locked event,
  so reaching here means the client asked anyway: this is the guard, not a
  hint.

  Deliberately re-read from the database rather than taken from the socket:
  the assigned lock set is as old as the last event load, and a seat booked
  since then must still count. Scoped to the acting organiser's meetings.
  """
  @spec check_seat_lock(Phoenix.LiveView.Socket.t(), map()) :: :ok | {:error, :group_booking}
  def check_seat_lock(socket, event),
    do: EditGuard.seat_lock(socket.assigns.current_user.id, event)

  @doc """
  Why an event `check_seat_lock/2` refuses cannot be changed here: the one
  wording the refusal flash, the locked badge and the event modal share.
  """
  @spec seat_lock_message() :: String.t()
  def seat_lock_message, do: CalendarEditMessages.seat_lock_message()

  @spec check_move_rate_limit(Phoenix.LiveView.Socket.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_move_rate_limit(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check(:calendar_event_move, user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  @spec check_quick_add_meeting_rate_limit(Phoenix.LiveView.Socket.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_quick_add_meeting_rate_limit(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check(:dashboard_quick_add_meeting, user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  # The domain's rule rather than a copy of it: an address the form accepts
  # has to be one `Meetings.Guests` keeps, or it is dropped after the host was
  # told it was fine.
  @spec valid_email?(term()) :: boolean()
  def valid_email?(email), do: Guests.valid_email?(email)

  @doc "See `ReminderForm.reminder_minutes_presets/0`."
  @spec reminder_minutes_presets() :: [pos_integer()]
  defdelegate reminder_minutes_presets(), to: ReminderForm

  @doc "See `ReminderForm.parse_reminder/1`."
  @spec parse_reminder(map()) :: {:ok, %{method: atom(), minutes_before: pos_integer()}} | :error
  defdelegate parse_reminder(params), to: ReminderForm

  @doc "See `RepeatForm.recurrence_timezone/2`."
  @spec recurrence_timezone(map() | nil, String.t() | nil) :: String.t() | nil
  defdelegate recurrence_timezone(event, user_timezone), to: RepeatForm

  @doc "See `RepeatForm.recurrence_start/2`."
  @spec recurrence_start(map(), String.t()) :: Date.t() | DateTime.t()
  defdelegate recurrence_start(event, user_timezone), to: RepeatForm

  @doc """
  What the repeat editor keeps for the event open in the details: the first
  start of its series (`Changes.series_start/1`), read once when the
  event is opened, and the pattern staged in the editor and not yet saved
  (`:draft`, `%{params: fields, rule: rule}`, or `nil`).

  Answers `nil` for an event whose calendar takes no repeat rule.
  """
  @spec recurrence_edit(map() | nil) :: map() | nil
  def recurrence_edit(%{id: id} = event) do
    if Changes.repeatable_provider?(Map.get(event, :provider)),
      do: %{event_id: id, series_start: Changes.series_start(event), draft: nil}
  end

  def recurrence_edit(_no_event), do: nil

  @doc """
  The start a repeat pattern of `event` is shown and built against: the
  first start of its series (see `recurrence_edit/1`), on the wall clock of
  the zone it repeats in, which is what a rule written to the whole series
  is read from. The second element says whether that start is known: a
  series whose first start was never read falls back to the event's own
  start, which only an edit of this and the following events is written
  against.
  """
  @spec series_anchor(map(), map() | nil, String.t()) :: {Date.t() | DateTime.t(), boolean()}
  def series_anchor(event, edit, user_timezone) do
    cond do
      # An event of no series begins where it starts now, whatever it was
      # opened at.
      not Series.member?(event) ->
        {recurrence_start(event, user_timezone), true}

      match?(%{event_id: id, series_start: %{}} when id == event.id, edit) ->
        {in_recurrence_zone(edit.series_start, event, user_timezone), true}

      true ->
        {recurrence_start(event, user_timezone), false}
    end
  end

  @doc "See `RepeatForm.in_recurrence_zone/3`."
  @spec in_recurrence_zone(Date.t() | DateTime.t(), map(), String.t()) :: Date.t() | DateTime.t()
  defdelegate in_recurrence_zone(start, event, user_timezone), to: RepeatForm

  @doc "The pattern staged in the repeat editor for `event`, or `nil` (see `recurrence_edit/1`)."
  @spec recurrence_draft(map(), map() | nil) :: %{params: map(), rule: String.t() | nil} | nil
  def recurrence_draft(%{id: id}, %{event_id: id, draft: draft}), do: draft
  def recurrence_draft(_event, _edit), do: nil

  @doc "See `RepeatForm.all_day_timezone/2`."
  @spec all_day_timezone(map(), String.t() | nil) :: String.t() | nil
  defdelegate all_day_timezone(event, user_timezone), to: RepeatForm

  @doc "See `RepeatForm.compose_recurrence_rule/2`."
  @spec compose_recurrence_rule(map(), map()) :: String.t() | nil | {:error, :until_before_start}
  defdelegate compose_recurrence_rule(params, event_context \\ %{}), to: RepeatForm

  # ---------------------------------------------------------------------------
  # Refactor 1 — optimistic-update plumbing
  # ---------------------------------------------------------------------------

  @doc """
  Replaces the event whose `id` matches `id` in `events` with `new_event`.
  Events whose id does not match are kept unchanged.
  """
  @spec replace_event([map()], integer(), map()) :: [map()]
  def replace_event(events, id, new_event) do
    Enum.map(events, fn e -> if e.id == id, do: new_event, else: e end)
  end

  @doc """
  Applies a standard optimistic-update cycle on the socket and fires an async
  update.

  Steps (order preserved from original `push_*` private functions in
  `InlineEdit`):
    1. Replace the event in `:events` by id.
    2. Assign `:selected_event` with the optimistic event.
    3. Assign `:events` with the updated list.
    4. Run `Helpers.precompute_derived/1`.
    5. Call `async_fun.(socket)` — the async function receives the
       post-assign socket and returns it after scheduling the task.

  Returns `{:noreply, socket}` — the standard LiveView reply tuple.
  """
  @spec apply_optimistic_update(
          Phoenix.LiveView.Socket.t(),
          map(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def apply_optimistic_update(socket, optimistic_event, async_fun) do
    updated_events =
      replace_event(socket.assigns.events, optimistic_event.id, optimistic_event)

    socket =
      socket
      |> assign(:selected_event, optimistic_event)
      |> assign(:events, updated_events)
      |> Helpers.precompute_derived()
      |> async_fun.()

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Refactor 2 — shared guard-error flash handler
  # ---------------------------------------------------------------------------

  @doc """
  Sends a flash message for guard errors that are duplicated across handlers
  and returns `{:noreply, socket}`.

  Handled errors:

    * `{:error, :unauthorized}` — "You don't have permission to modify this event"
    * `{:error, :read_only}` — "This calendar is read-only..."
    * `{:error, :rate_limited, _message}` — "Too many edits. Please wait a moment."
    * `{:error, :group_booking}`: a group meeting with live seats sits on the event

  Flash messages are sent via `send(self(), {:flash, ...})` (the LiveComponent
  pattern; `put_flash/3` does not propagate from LiveComponents).
  """
  @spec flash_guard_error(Phoenix.LiveView.Socket.t(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def flash_guard_error(socket, error), do: {:noreply, flash_guard(socket, error)}

  @doc """
  The socket-returning form of `flash_guard_error/2`, for callers already
  inside a continuation that has to hand a socket back.
  """
  @spec flash_guard(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def flash_guard(socket, {:error, :until_before_start}) do
    send(self(), {:flash, {:error, until_before_start_message()}})

    socket
  end

  def flash_guard(socket, error) do
    send(self(), {:flash, CalendarEditMessages.refusal(error)})
    socket
  end

  @doc "What the organiser is told when a repeat rule would end before the event starts."
  @spec until_before_start_message() :: String.t()
  def until_before_start_message,
    do:
      dgettext(
        "dashboard_calendar_events",
        "The recurrence end date must be on or after the event start."
      )

  # ---------------------------------------------------------------------------
  # Refactor 3 — optional int parsing and reminder-list helpers
  # ---------------------------------------------------------------------------

  @doc """
  Parses an optional integer from a string, binary, or integer value.

  Returns an integer when the input is a non-empty string that parses cleanly,
  or an integer passed through. Returns `nil` for `nil`, `""`, or any value
  that does not parse as a bare integer.

  Identical logic to the private `parse_video_integration_id/1` in
  `InlineEdit` and `maybe_put_int/3` in `CreateFormState`.
  """
  @spec parse_optional_int(nil | binary() | integer()) :: integer() | nil
  def parse_optional_int(nil), do: nil
  def parse_optional_int(""), do: nil

  def parse_optional_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _other -> nil
    end
  end

  def parse_optional_int(val) when is_integer(val), do: val
  def parse_optional_int(_other), do: nil

  @doc "See `ReminderForm.add_reminder/2`."
  @spec add_reminder([map()], map()) :: [map()]
  defdelegate add_reminder(reminders, reminder), to: ReminderForm
end
