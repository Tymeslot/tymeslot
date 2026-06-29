defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared do
  @moduledoc "Shared helpers used across EventHandlers submodules."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @weekday_atoms %{
    "mo" => :mo,
    "tu" => :tu,
    "we" => :we,
    "th" => :th,
    "fr" => :fr,
    "sa" => :sa,
    "su" => :su
  }

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
  # Returns `{:ok, utc_datetime}` on success. DST edge cases are handled
  # gracefully rather than crashing:
  #   - Gap (spring-forward): the time falls in the skipped hour; we use
  #     `just_after` (the first valid instant post-gap) so the event is placed
  #     at the nearest valid local time rather than raising.
  #   - Ambiguous (fall-back): the time occurs twice; we pick `first` (the
  #     DST instant) which is the intuitive choice when someone schedules a
  #     meeting "at 1:30am" before they know the clocks fall back.
  #   - Other errors: propagated as `{:error, reason}` so callers can surface
  #     a flash instead of crashing the LiveView.
  @spec to_utc(Date.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def to_utc(date, hour, minute, timezone) do
    time = Time.new!(hour, minute, 0, {0, 6})

    case DateTime.new(date, time, timezone) do
      {:ok, dt} ->
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

      {:gap, _just_before, just_after} ->
        {:ok, DateTime.shift_zone!(just_after, "Etc/UTC")}

      {:ambiguous, first, _second} ->
        {:ok, DateTime.shift_zone!(first, "Etc/UTC")}

      {:error, reason} ->
        {:error, reason}
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

    case RateLimiter.check_calendar_event_edit_rate_limit(user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  @spec check_move_rate_limit(Phoenix.LiveView.Socket.t()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_move_rate_limit(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_calendar_event_move_rate_limit(user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  @spec valid_email?(binary()) :: boolean()
  @spec valid_email?(term()) :: false
  def valid_email?(email) when is_binary(email) do
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end

  def valid_email?(_other), do: false

  # Allowed reminder lead times (minutes before the event start) offered as
  # presets in the editor. Values outside this set are rejected so the UI
  # cannot feed arbitrary integers into the provider write.
  @reminder_minutes_presets [5, 10, 30, 60, 1440]

  @doc """
  Returns the allowed reminder lead times in minutes, ordered ascending.
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

  @doc """
  Composes a canonical RRULE string from the recurrence editor's raw form
  fields (`freq`, `interval`, `by_day[]`, `end_type`, `count`, `until`).

  Returns `nil` when no frequency is chosen ("Does not repeat") or the fields do
  not describe a valid rule. Unrecognised frequencies and malformed end
  conditions degrade gracefully — a bad `count` simply yields a never-ending
  rule rather than failing.

  The optional `event_context` map may include:
    - `:start_date` — a `Date.t()` used to reject an `until` that precedes the
      event start (which would produce a dead rule with zero occurrences).
    - `:all_day` — a boolean that controls UNTIL value-type: all-day recurring
      events must emit `UNTIL=YYYYMMDD` (RFC 5545 §3.3.10) rather than the
      default UTC date-time form.

  Returns `{:error, :until_before_start}` when `until` precedes `:start_date`.
  """
  @spec compose_recurrence_rule(map(), map()) :: String.t() | nil | {:error, :until_before_start}
  def compose_recurrence_rule(params, event_context \\ %{}) do
    case parse_freq(params["freq"]) do
      nil ->
        nil

      freq ->
        all_day = Map.get(event_context, :all_day, false)
        start_date = Map.get(event_context, :start_date)

        opts =
          %{freq: freq}
          |> put_interval(params["interval"])
          |> put_by_day(freq, params["by_day"])
          |> put_end_condition(params["end_type"], params)

        with :ok <- validate_until_after_start(opts, start_date) do
          RRule.build(opts, all_day: all_day)
        end
    end
  end

  # Returns :ok when there is no UNTIL, no start_date to compare, or when
  # UNTIL is on or after the start date. Returns {:error, :until_before_start}
  # when the rule would expand to zero occurrences.
  defp validate_until_after_start(%{until: until}, %Date{} = start_date) do
    if Date.compare(until, start_date) == :lt do
      {:error, :until_before_start}
    else
      :ok
    end
  end

  defp validate_until_after_start(_opts, _no_start), do: :ok

  defp parse_freq("daily"), do: :daily
  defp parse_freq("weekly"), do: :weekly
  defp parse_freq("monthly"), do: :monthly
  defp parse_freq("yearly"), do: :yearly
  defp parse_freq(_other), do: nil

  defp put_interval(opts, value) do
    case parse_int(value || "") do
      {:ok, n} when n > 1 -> Map.put(opts, :interval, n)
      _other -> opts
    end
  end

  defp put_by_day(opts, :weekly, days) when is_list(days) do
    by_day =
      days
      |> Enum.map(&Map.get(@weekday_atoms, &1))
      |> Enum.reject(&is_nil/1)

    if by_day == [], do: opts, else: Map.put(opts, :by_day, by_day)
  end

  defp put_by_day(opts, _freq, _days), do: opts

  defp put_end_condition(opts, "count", params) do
    case parse_int(params["count"] || "") do
      {:ok, n} when n > 0 -> Map.put(opts, :count, n)
      _other -> opts
    end
  end

  defp put_end_condition(opts, "until", params) do
    case Date.from_iso8601(params["until"] || "") do
      {:ok, date} -> Map.put(opts, :until, date)
      {:error, _reason} -> opts
    end
  end

  defp put_end_condition(opts, _never_or_other, _params), do: opts

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
    * `{:error, :rate_limited, _message}` — "Too many edits. Please wait a moment."

  Flash messages are sent via `send(self(), {:flash, ...})` (the LiveComponent
  pattern; `put_flash/3` does not propagate from LiveComponents).
  """
  @spec flash_guard_error(Phoenix.LiveView.Socket.t(), term()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def flash_guard_error(socket, {:error, :unauthorized}) do
    send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
    {:noreply, socket}
  end

  def flash_guard_error(socket, {:error, :rate_limited, _message}) do
    send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
    {:noreply, socket}
  end

  def flash_guard_error(socket, {:error, :until_before_start}) do
    send(
      self(),
      {:flash, {:error, "The recurrence end date must be on or after the event start."}}
    )

    {:noreply, socket}
  end

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
