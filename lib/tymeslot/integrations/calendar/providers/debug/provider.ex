defmodule Tymeslot.Integrations.Calendar.DebugCalendarProvider do
  @moduledoc """
  Debug calendar provider backed by the in-memory `DebugStore`.

  Implements the full `Provider` behaviour (create/update/delete/list/normalise)
  against `Tymeslot.Integrations.Calendar.DebugStore`, the single store shared
  with the interactive dev calendar (`Tymeslot.Dev.Calendar`). This makes the
  debug calendar a genuine source of truth for the dashboard calendar grid:
  events created or edited in the grid round-trip with all their rich fields
  (recurrence, reminders, colour, all-day, location, description, attendees) and
  also show as busy on the booking page, and vice-versa.

  The recurring `pattern` + explicit `rules` are projected into busy blocks by
  the pure `DebugSchedule` generator; in-app events are stored verbatim. All
  store access tolerates the store not running (e.g. in `:test`, or dev without
  the interactive calendar enabled) — reads then return an empty set.

  Only wired up in development/test via the `debug` integration provider.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.DebugSchedule
  alias Tymeslot.Integrations.Calendar.DebugStore

  # Synthetic events have no real timezone; default to UTC for the provider path.
  # The interactive dev calendar (`Tymeslot.Dev.Calendar`) resolves the
  # organiser's timezone instead.
  @default_timezone "Etc/UTC"

  @impl Tymeslot.Integrations.Calendar.Provider
  def new(config) when is_map(config) do
    case validate_config(config) do
      :ok -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def create_event(_client, event_data) do
    uid = Map.fetch!(event_data, :uid)

    event_data
    |> stored_event_from(uid)
    |> DebugStore.put_event()

    {:ok, %{uid: uid}}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(_client, uid, event_data) do
    existing =
      case DebugStore.fetch_event(uid) do
        {:ok, event} -> event
        :error -> %{}
      end

    merged = Map.merge(existing, stored_event_from(event_data, uid))
    DebugStore.put_event(merged)
    :ok
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(_client, uid, _opts \\ []) do
    DebugStore.delete_event(uid)
    :ok
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :debug

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Debug Calendar (Development Only)"

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      user_id: %{
        type: :integer,
        required: true,
        description: "User ID for debug calendar"
      }
    }
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    if Map.has_key?(config, :user_id) do
      :ok
    else
      {:error, "user_id is required for debug calendar provider"}
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def build_client_configs(integration) do
    if Application.get_env(:tymeslot, :environment) in [:dev, :test] do
      [%{user_id: integration.user_id}]
    else
      []
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def build_booking_client_config(_integration), do: nil

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(_client, opts) do
    start_time = opts[:start_time] || DateTime.add(DateTime.utc_now(), -7, :day)
    end_time = opts[:end_time] || DateTime.add(DateTime.utc_now(), 30, :day)

    %{pattern: pattern, rules: rules, events: events} = DebugStore.snapshot()

    generated =
      pattern
      |> DebugSchedule.events(rules, start_time, end_time, @default_timezone)
      |> Enum.map(&Map.put(&1, :created_by_tymeslot, false))

    created = events_in_range(Map.values(events), start_time, end_time)

    {:ok, generated ++ created}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(raw_events, context) when is_list(raw_events) do
    events = Enum.map(raw_events, &normalise_event(&1, context))
    {:ok, events}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(_client), do: {:ok, %{status: :skipped, reason: "Debug provider"}}

  @doc """
  Tests the connection for the debug calendar provider.
  Always returns success since this is a test provider.
  """
  @spec test_connection(map()) :: {:ok, String.t()}
  def test_connection(_integration) do
    {:ok, "Debug calendar connection successful"}
  end

  # --- Helpers ---------------------------------------------------------------

  # Builds the rich stored-event map from incoming event_data, keeping only the
  # fields the debug calendar round-trips. start_time/end_time are stored
  # verbatim (Date for all-day, DateTime for timed).
  defp stored_event_from(event_data, uid) do
    event_data
    |> Map.take([
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
    |> Map.put(:uid, uid)
    |> Map.put_new(:all_day, false)
    |> Map.put(:status, "confirmed")
    |> Map.put(:created_by_tymeslot, true)
  end

  # Keeps stored events overlapping the range. Timed events compare directly;
  # all-day events are projected to a day-spanning block for the overlap check
  # but returned verbatim so normalisation can emit start_date/end_date.
  defp events_in_range(events, range_start, range_end) do
    Enum.filter(events, &overlaps?(&1, range_start, range_end))
  end

  defp overlaps?(
         %{all_day: true, start_time: %Date{} = start_date} = event,
         range_start,
         range_end
       ) do
    end_date = Map.get(event, :end_time, start_date)
    block_start = day_start(start_date)
    block_end = day_start(Date.add(end_date, 1))

    DateTime.compare(block_start, range_end) == :lt and
      DateTime.compare(block_end, range_start) == :gt
  end

  defp overlaps?(
         %{start_time: %DateTime{} = start_time, end_time: %DateTime{} = end_time},
         range_start,
         range_end
       ) do
    DateTime.compare(start_time, range_end) == :lt and
      DateTime.compare(end_time, range_start) == :gt
  end

  defp overlaps?(_event, _range_start, _range_end), do: false

  defp day_start(%Date{} = date) do
    DateTime.new!(date, ~T[00:00:00], @default_timezone)
  end

  # --- Normalisation ---------------------------------------------------------

  defp normalise_event(raw, context) do
    raw
    |> base_attrs(context)
    |> Map.merge(timing_attrs(raw))
    |> CalendarEvent.new!()
  end

  defp base_attrs(raw, context) do
    %{
      uid: Map.fetch!(raw, :uid),
      calendar_integration_id: context.calendar_integration_id,
      provider: :debug,
      provider_calendar_id: Map.get(raw, :provider_calendar_id) || context.provider_calendar_id,
      synced_at: context.synced_at,
      summary: Map.get(raw, :summary),
      description: Map.get(raw, :description),
      location: Map.get(raw, :location),
      recurrence_rule: Map.get(raw, :recurrence_rule),
      reminders: Map.get(raw, :reminders) || [],
      colour: Map.get(raw, :colour),
      attendees: Map.get(raw, :attendees) || [],
      status: :confirmed,
      transparency: :opaque,
      created_by_tymeslot: Map.get(raw, :created_by_tymeslot, false)
    }
  end

  defp timing_attrs(%{all_day: true, start_time: %Date{} = start_date} = raw) do
    %{
      all_day: true,
      start_date: start_date,
      end_date: Map.get(raw, :end_time, start_date)
    }
  end

  defp timing_attrs(%{start_time: %DateTime{} = start_at, end_time: %DateTime{} = end_at}) do
    %{
      all_day: false,
      start_at: start_at,
      end_at: end_at
    }
  end
end
