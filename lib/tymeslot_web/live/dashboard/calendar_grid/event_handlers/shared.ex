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
  # The timezone is validated at mount time (DataLoading.precompute_derived/1), so
  # it is safe to use the bang variant here.
  @spec to_utc(Date.t(), non_neg_integer(), non_neg_integer(), String.t()) :: DateTime.t()
  def to_utc(date, hour, minute, timezone) do
    local_dt = DateTime.new!(date, Time.new!(hour, minute, 0, {0, 6}), timezone)
    DateTime.shift_zone!(local_dt, "Etc/UTC")
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
  conditions degrade gracefully — a bad `count`/`until` simply yields a
  never-ending rule rather than failing.
  """
  @spec compose_recurrence_rule(map()) :: String.t() | nil
  def compose_recurrence_rule(params) do
    case parse_freq(params["freq"]) do
      nil ->
        nil

      freq ->
        %{freq: freq}
        |> put_interval(params["interval"])
        |> put_by_day(freq, params["by_day"])
        |> put_end_condition(params["end_type"], params)
        |> RRule.build()
    end
  end

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
