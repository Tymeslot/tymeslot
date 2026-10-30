defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared do
  @moduledoc "Shared helpers used across EventHandlers submodules."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.DateTimeUtils
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
  def check_edit_rate_limit(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check(:calendar_event_edit, user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

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
  def check_seat_lock(socket, event) do
    if Meetings.group_booking_uid?(socket.assigns.current_user.id, Map.get(event, :uid)) do
      {:error, :group_booking}
    else
      :ok
    end
  end

  @doc """
  Why an event `check_seat_lock/2` refuses cannot be changed here: the one
  wording the refusal flash, the locked badge and the event modal share.
  """
  @spec seat_lock_message() :: String.t()
  def seat_lock_message do
    dgettext(
      "dashboard_calendar_events",
      "This is a group booking. Move it, cancel it or change who attends from the meeting instead."
    )
  end

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

  # Allowed reminder lead times (minutes before the event start) offered as
  # presets in the editor. Values outside this set are rejected so the UI
  # cannot feed arbitrary integers into the provider write.
  @reminder_minutes_presets [5, 10, 30, 60, 1440]

  @doc """
  Returns the allowed reminder lead times (minutes before the event start).
  This is the single source of truth for the preset whitelist: `parse_reminder/1`
  rejects anything outside it, and `RemindersEditor` builds the editor's options
  from this list rather than duplicating the values.
  """
  @spec reminder_minutes_presets() :: [pos_integer()]
  def reminder_minutes_presets, do: @reminder_minutes_presets

  @doc """
  Parses a reminder from `phx-value-method` / `phx-value-minutes` params into the
  canonical `%{method: :popup | :email, minutes_before: integer}` shape. Returns
  `:error` for an unknown method or a lead time outside the allowed presets.
  """
  @spec parse_reminder(map()) :: {:ok, %{method: atom(), minutes_before: pos_integer()}} | :error
  def parse_reminder(params) do
    with {:ok, method} <- parse_reminder_method(params["method"]),
         {:ok, minutes} <- parse_int(params["minutes"]),
         true <- minutes in @reminder_minutes_presets do
      {:ok, %{method: method, minutes_before: minutes}}
    else
      _invalid -> :error
    end
  end

  defp parse_reminder_method("popup"), do: {:ok, :popup}
  defp parse_reminder_method("email"), do: {:ok, :email}
  defp parse_reminder_method(_other), do: :error

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
  def flash_guard(socket, {:error, :unauthorized}) do
    send(
      self(),
      {:flash,
       {:error,
        dgettext("dashboard_calendar_events", "You don't have permission to modify this event")}}
    )

    socket
  end

  def flash_guard(socket, {:error, :read_only}) do
    send(
      self(),
      {:flash,
       {:error,
        dgettext(
          "dashboard_calendar_events",
          "This calendar is read-only. Events on it can't be changed from Tymeslot."
        )}}
    )

    socket
  end

  def flash_guard(socket, {:error, :rate_limited, _message}) do
    send(
      self(),
      {:flash,
       {:warning, dgettext("dashboard_calendar_events", "Too many edits. Please wait a moment.")}}
    )

    socket
  end

  def flash_guard(socket, {:error, :group_booking}) do
    send(self(), {:flash, {:warning, seat_lock_message()}})
    socket
  end

  def flash_guard(socket, {:error, :until_before_start}) do
    send(self(), {:flash, {:error, until_before_start_message()}})

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

  @doc """
  Adds `reminder` to `reminders` if it is not already present (dedup).

  Returns the updated list unchanged when `reminder` is already in it.
  """
  @spec add_reminder([map()], map()) :: [map()]
  def add_reminder(reminders, reminder) do
    if reminder in reminders, do: reminders, else: reminders ++ [reminder]
  end
end
