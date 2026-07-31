defmodule Tymeslot.Dev.Calendar do
  @moduledoc """
  Interactive development calendar stub.

  Compiled only in `:dev` (see the `dev/support` entry in `elixirc_paths/1` in
  `mix.exs`) and never bundled into release builds. Opt in by setting
  `DEV_CALENDAR=1` (starts with a realistic recurring weekly pattern) or
  `DEV_EMPTY_CALENDAR=1` (starts empty — every slot free); both wire it in via
  `config :tymeslot, :calendar_module` in `config/dev.exs`.

  Unlike a fixed stub, availability is **controllable live from IEx** — block a
  date or add a busy period, refresh the booking page, and see the effect with
  no recompile or restart:

      iex> Tymeslot.Dev.Calendar.block(~D[2026-06-30])
      iex> Tymeslot.Dev.Calendar.busy(~D[2026-06-25], ~T[10:00:00], ~T[11:00:00])
      iex> Tymeslot.Dev.Calendar.pattern(:empty)
      iex> Tymeslot.Dev.Calendar.clear()
      iex> Tymeslot.Dev.Calendar.list()

  Events are generated relative to today by `Tymeslot.Integrations.Calendar.DebugSchedule`
  (the shared, pure generator that the `:debug` provider uses too), resolved in
  the organiser's timezone. Rules and in-app events live in the supervised
  `Tymeslot.Integrations.Calendar.DebugStore` Agent — the single store shared
  with the dashboard calendar grid — and reset to the configured default pattern
  on restart.

  Events **created in-app** (e.g. confirming a booking) are accepted too: they
  are recorded in the same in-memory store and immediately occupy their slot, so
  a freshly-booked time shows as busy and cancelling it frees the slot again.
  Nothing is persisted — a restart clears them along with the rest.

  To exercise genuine calendar sync locally, leave both variables unset and the
  real `Calendar.Operations` module is used.
  """

  @behaviour Tymeslot.Integrations.Calendar.CalendarBehaviour

  alias Tymeslot.Integrations.Calendar.DebugSchedule
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Profiles.ProfileQueries

  @default_timezone "Etc/UTC"

  # --- Interactive IEx API ---------------------------------------------------

  @doc "Marks a whole day busy. Returns the updated rule list."
  @spec block(Date.t()) :: [DebugSchedule.rule()]
  def block(%Date{} = date), do: DebugStore.add_rule({:block_date, date})

  @doc """
  Marks a single period busy on `date`. Returns the updated rule list, or
  `{:error, :invalid_range}` when `end_time` is not after `start_time`.
  """
  @spec busy(Date.t(), Time.t(), Time.t()) :: [DebugSchedule.rule()] | {:error, :invalid_range}
  def busy(%Date{} = date, %Time{} = start_time, %Time{} = end_time) do
    if Time.compare(end_time, start_time) == :gt do
      DebugStore.add_rule({:busy, date, start_time, end_time})
    else
      {:error, :invalid_range}
    end
  end

  @doc "Swaps the recurring pattern (`:default` or `:empty`). Returns the pattern."
  @spec pattern(DebugSchedule.pattern()) :: DebugSchedule.pattern()
  def pattern(pattern) when pattern in [:default, :empty], do: DebugStore.set_pattern(pattern)

  @doc "Removes all explicit busy/blocked rules, keeping the recurring pattern."
  @spec clear() :: :ok
  def clear, do: DebugStore.clear()

  @doc "Lists the current explicit busy/blocked rules."
  @spec list() :: [DebugSchedule.rule()]
  def list, do: DebugStore.snapshot().rules

  # --- CalendarBehaviour -----------------------------------------------------

  @impl true
  def get_events_for_range_fresh(user_id, %Date{} = start_date, %Date{} = end_date) do
    timezone = timezone_for(user_id)
    range_start = day_start(start_date, timezone)
    range_end = day_start(Date.add(end_date, 1), timezone)
    {:ok, generate(user_id, range_start, range_end, timezone)}
  end

  @impl true
  def get_events_for_month(user_id, year, month, timezone) do
    start_date = Date.new!(year, month, 1)
    end_date = Date.end_of_month(start_date)
    range_start = day_start(start_date, timezone)
    range_end = day_start(Date.add(end_date, 1), timezone)
    {:ok, generate(user_id, range_start, range_end, timezone)}
  end

  @impl true
  def get_event(uid, _user_id) do
    case DebugStore.fetch_event(uid) do
      {:ok, event} -> {:ok, event}
      :error -> {:error, :not_found}
    end
  end

  # Records the event in-memory so a booking made in-app immediately shows as
  # busy on the debug calendar. Keyed by the meeting uid carried in event_data,
  # so later update/delete target the same entry.
  @impl true
  def create_event(event_data, _context) do
    case record_event(event_data) do
      {:ok, uid} -> {:ok, %{uid: uid}}
      :ignore -> {:ok, %{uid: "dev-stub-event"}}
    end
  end

  @impl true
  def update_event(uid, event_data, _context) do
    record_event(Map.put(event_data, :uid, uid))
    :ok
  end

  @impl true
  def delete_event(uid, _context) do
    DebugStore.delete_event(uid)
    :ok
  end

  @impl true
  def get_booking_integration_info(_context), do: {:error, :no_integration}

  # --- Helpers ---------------------------------------------------------------

  defp generate(_user_id, range_start, range_end, timezone) do
    %{pattern: pattern, rules: rules, events: events} = DebugStore.snapshot()

    generated = DebugSchedule.events(pattern, rules, range_start, range_end, timezone)

    in_app =
      events
      |> Map.values()
      |> Enum.map(&to_busy_block(&1, timezone))
      |> DebugSchedule.in_range(range_start, range_end)

    Enum.sort_by(generated ++ in_app, & &1.start_time, DateTime)
  end

  # Projects a rich stored event to the booking busy-block shape. All-day events
  # span from the start of their first day to the start of the day after their
  # last day in the resolved timezone, so they still occupy availability.
  defp to_busy_block(%{all_day: true, start_time: %Date{} = start_date} = event, timezone) do
    end_date = Map.get(event, :end_time, start_date)

    %{
      uid: event.uid,
      summary: Map.get(event, :summary) || "Booked (dev)",
      start_time: day_start(start_date, timezone),
      end_time: day_start(Date.add(end_date, 1), timezone),
      status: Map.get(event, :status, "confirmed")
    }
  end

  defp to_busy_block(
         %{start_time: %DateTime{} = start_time, end_time: %DateTime{} = end_time} = event,
         _timezone
       ) do
    %{
      uid: event.uid,
      summary: Map.get(event, :summary) || "Booked (dev)",
      start_time: start_time,
      end_time: end_time,
      status: Map.get(event, :status, "confirmed")
    }
  end

  # Stores a created/updated event when it carries the times needed to occupy a
  # slot. Returns the uid used, or `:ignore` when the payload is unusable.
  defp record_event(%{uid: uid, start_time: %DateTime{}, end_time: %DateTime{}} = event_data)
       when is_binary(uid) do
    store_event(event_data)
    {:ok, uid}
  end

  defp record_event(%{uid: uid, all_day: true, start_time: %Date{}} = event_data)
       when is_binary(uid) do
    store_event(event_data)
    {:ok, uid}
  end

  defp record_event(_event_data), do: :ignore

  defp store_event(event_data) do
    event_data
    |> Map.take([
      :uid,
      :summary,
      :description,
      :location,
      :all_day,
      :start_time,
      :end_time,
      :reminders,
      :recurrence_rule,
      :colour,
      :attendees,
      :provider_calendar_id
    ])
    |> Map.put_new(:summary, "Booked (dev)")
    |> Map.put_new(:all_day, false)
    |> Map.put(:status, "confirmed")
    |> Map.put(:created_by_tymeslot, true)
    |> DebugStore.put_event()
  end

  defp timezone_for(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, %{timezone: timezone}} when is_binary(timezone) and timezone != "" -> timezone
      _otherwise -> @default_timezone
    end
  end

  defp day_start(date, timezone) do
    case DateTime.new(date, ~T[00:00:00], timezone) do
      {:ok, datetime} -> datetime
      {:ambiguous, datetime, _later} -> datetime
      {:gap, _before, datetime} -> datetime
      {:error, _reason} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end
end
