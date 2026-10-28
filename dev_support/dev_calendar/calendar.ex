defmodule Tymeslot.Dev.Calendar do
  @moduledoc """
  Interactive development calendar stub.

  Compiled only in `:dev` (see the `dev_support/dev_calendar` entry in `elixirc_paths/1` in
  `mix.exs`) and never bundled into release builds. Opt in by setting
  `DEV_CALENDAR=1` (starts with a realistic recurring weekly pattern) or
  `DEV_EMPTY_CALENDAR=1` (starts empty, every slot free); both wire it in via
  `config :tymeslot, :calendar_module` in `config/dev.exs`.

  Unlike a fixed stub, availability is **controllable live from IEx**: block a
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
  `Tymeslot.Integrations.Calendar.DebugStore` Agent, the single store shared
  with the dashboard calendar grid, and reset to the configured default pattern
  on restart.

  Events **created in-app** (e.g. confirming a booking) are accepted too: they
  are recorded in the same in-memory store and immediately occupy their slot, so
  a freshly-booked time shows as busy and cancelling it frees the slot again.
  Nothing is persisted: a restart clears them along with the rest.

  To exercise genuine calendar sync locally, leave both variables unset and the
  real `Calendar.Runtime.Operations` module is used.
  """

  @behaviour Tymeslot.Integrations.Calendar.CalendarBehaviour

  alias Tymeslot.Integrations.Calendar.CalendarBehaviour
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider
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

  @impl CalendarBehaviour
  def get_events_for_range_fresh(user_id, %Date{} = start_date, %Date{} = end_date) do
    timezone = timezone_for(user_id)
    range_start = day_start(start_date, timezone)
    range_end = day_start(Date.add(end_date, 1), timezone)
    {:ok, generate(user_id, range_start, range_end, timezone)}
  end

  # Stored through the debug provider, like every other write, so a booking
  # made in-app immediately shows as busy and a series is kept as an
  # iCalendar document in a timezone. Keyed by the meeting uid carried in
  # event_data, so later update/delete target the same entry.
  @impl CalendarBehaviour
  def create_event(event_data, _context) do
    if recordable?(event_data) do
      event_data = Map.put_new(event_data, :timezone, @default_timezone)
      DebugCalendarProvider.create_event(nil, event_data)
    else
      {:ok, CreatedEvent.new("dev-stub-event")}
    end
  end

  # Edits and deletes go through the debug provider, so an edit of one
  # occurrence of a series, or of the series from one occurrence, is stored
  # exactly as it is on a dev server without this stub.
  @impl CalendarBehaviour
  def update_event(uid, event_data, _context),
    do: DebugCalendarProvider.update_event(nil, uid, event_data)

  @impl CalendarBehaviour
  def delete_event(uid, _context, opts),
    do: DebugCalendarProvider.delete_event(nil, uid, opts)

  # The stub holds no provider to ask, so a read straight from one is the
  # answer a provider without single-event fetches gives.
  @impl CalendarBehaviour
  def fetch_event(_event_ref, _context), do: {:error, :unsupported}

  @impl CalendarBehaviour
  def get_booking_integration_info(_context), do: {:error, :no_integration}

  # --- Helpers ---------------------------------------------------------------

  defp generate(_user_id, range_start, range_end, timezone) do
    %{pattern: pattern, rules: rules} = DebugStore.snapshot()

    generated = DebugSchedule.events(pattern, rules, range_start, range_end, timezone)

    in_app =
      range_start
      |> DebugCalendarProvider.stored_events_in_range(range_end)
      |> Enum.map(&to_busy_block(&1, timezone))

    Enum.sort_by(generated ++ in_app, & &1.start_time, DateTime)
  end

  # Projects a rich stored event to the booking busy-block shape. All-day events
  # span from the start of their first day to the start of their (exclusive)
  # end date in the resolved timezone, so they still occupy availability.
  defp to_busy_block(%{all_day: true, start_time: %Date{} = start_date} = event, timezone) do
    end_date = Enum.max([Map.get(event, :end_time, start_date), Date.add(start_date, 1)], Date)

    %{
      uid: event.uid,
      summary: Map.get(event, :summary) || "Booked (dev)",
      start_time: day_start(start_date, timezone),
      end_time: day_start(end_date, timezone),
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

  # Whether an event carries the times needed to occupy a slot.
  defp recordable?(%{uid: uid, start_time: %DateTime{}, end_time: %DateTime{}})
       when is_binary(uid),
       do: true

  defp recordable?(%{uid: uid, all_day: true, start_time: %Date{}}) when is_binary(uid), do: true
  defp recordable?(_event_data), do: false

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
