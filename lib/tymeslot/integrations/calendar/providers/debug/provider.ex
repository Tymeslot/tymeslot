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
  store access tolerates the store not running: it runs on every dev server, in
  `:test` only when a test starts it, and reads then fall back to the default
  pattern (not an empty set).

  Only wired up in development/test via the `debug` integration provider.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.DebugSchedule
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

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

    {:ok, CreatedEvent.new(uid)}
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
  def delete_event(_client, uid, _opts) do
    DebugStore.delete_event(uid)
    :ok
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :debug

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Debug Calendar (Development Only)"

  @impl Tymeslot.Integrations.Calendar.Provider
  def connection_test_bucket, do: :unmetered

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
    if dev_or_test?(), do: [%{user_id: integration.user_id}], else: []
  end

  # Every write the calendar makes (create, edit, delete) resolves its client
  # through this config. Without one, each answered :no_calendar_integration
  # wherever the interactive dev stub was not compiled in.
  @impl Tymeslot.Integrations.Calendar.Provider
  def build_booking_client_config(integration) do
    if dev_or_test?(), do: %{user_id: integration.user_id}, else: nil
  end

  defp dev_or_test?, do: Application.get_env(:tymeslot, :environment) in [:dev, :test]

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(_client, opts) do
    start_time = opts[:start_time] || DateTime.add(DateTime.utc_now(), -7, :day)
    end_time = opts[:end_time] || DateTime.add(DateTime.utc_now(), 30, :day)

    %{pattern: pattern, rules: rules, events: events} = DebugStore.snapshot()

    generated =
      pattern
      |> DebugSchedule.events(rules, start_time, end_time, @default_timezone)
      |> Enum.map(&Map.put(&1, :created_by_tymeslot, false))

    created = stored_in_range(Map.values(events), start_time, end_time)

    {:ok, generated ++ created}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events_representation, do: :raw

  @impl Tymeslot.Integrations.Calendar.Provider
  def convert_events(events), do: events

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
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec perform_connection_test(map()) :: {:ok, String.t()}
  def perform_connection_test(_integration) do
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
      :provider_calendar_id,
      :timezone
    ])
    |> Map.put(:uid, uid)
    |> Map.put_new(:all_day, false)
    |> Map.put(:status, "confirmed")
    |> Map.put(:created_by_tymeslot, true)
  end

  @doc """
  The stored events overlapping `[range_start, range_end)`, with every
  repeating one expanded into its occurrences the way the CalDAV family
  caches a series: one row per occurrence, under the series' uid and the
  occurrence's key, all sharing the series' address (`series_href/1`).
  Skipped occurrences (`:exdates`) are left out and changed ones
  (`:overrides`) carry their changes. All-day events are projected to
  day-spanning blocks for the overlap check but returned with their dates.
  """
  @spec stored_events_in_range(DateTime.t(), DateTime.t()) :: [map()]
  def stored_events_in_range(range_start, range_end),
    do: stored_in_range(Map.values(DebugStore.snapshot().events), range_start, range_end)

  @doc "Where a debug series is addressed, as a CalDAV resource is by its href."
  @spec series_href(String.t()) :: String.t()
  def series_href(uid), do: "debug:#{uid}"

  defp stored_in_range(events, range_start, range_end) do
    events
    |> Enum.flat_map(&occurrences(&1, range_start, range_end))
    |> Enum.filter(&overlaps?(&1, range_start, range_end))
  end

  defp occurrences(%{recurrence_rule: rule} = master, range_start, range_end)
       when is_binary(rule) and rule != "" do
    zone = series_zone(master)
    skipped = Map.get(master, :exdates, [])
    overrides = Map.get(master, :overrides, %{})

    shifted =
      Map.merge(master, %{
        start_time: in_zone(master.start_time, zone),
        end_time: in_zone(Map.get(master, :end_time) || master.start_time, zone)
      })

    span = span_seconds(shifted)

    # Expand wider than the range by the series' span and a day, so an
    # occurrence that began before it (a long one, or an all-day one west of
    # UTC) is found; `overlaps?/3` trims the rest.
    expanded =
      shifted
      |> RecurrenceExpander.expand(
        DateTime.add(range_start, -(span + 86_400), :second),
        range_end
      )
      |> Map.new(&{occurrence_key(&1.start_time), &1})

    # A moved occurrence may sit in the range though its original slot does
    # not, so every override that moves one the rule really makes is listed
    # too, and trimmed by its own times. An override that changes no time
    # keeps the master's, which belong to another slot, so it lists only with
    # its expanded slot; a key the rule no longer produces (a series cut
    # short by a later edit) lists nothing.
    moved =
      overrides
      |> Enum.filter(fn {key, change} ->
        Map.has_key?(change, :start_time) and not Map.has_key?(expanded, key) and
          slot_exists?(shifted, key, zone)
      end)
      |> Map.new(fn {key, _change} -> {key, shifted} end)

    expanded
    |> Map.merge(moved)
    |> Enum.reject(fn {key, _occurrence} -> key in skipped end)
    |> Enum.map(fn {key, occurrence} ->
      occurrence
      |> Map.drop([:exdates, :overrides])
      |> Map.merge(override_with_end(Map.get(overrides, key, %{}), span))
      # The series' identity always wins over an override's.
      |> Map.merge(%{
        uid: "#{master.uid}_#{key}",
        provider_event_id: series_href(master.uid),
        provider_metadata: %{uid: master.uid},
        timezone: zone
      })
    end)
  end

  defp occurrences(event, _range_start, _range_end), do: [event]

  # A stored zone the tz database does not know falls back to the default.
  defp series_zone(event) do
    zone = Map.get(event, :timezone) || @default_timezone

    case DateTime.shift_zone(~U[2000-01-01 00:00:00Z], zone) do
      {:ok, _shifted} -> zone
      {:error, _reason} -> @default_timezone
    end
  end

  defp span_seconds(%{all_day: true, start_time: %Date{} = start, end_time: %Date{} = finish}),
    do: (Date.diff(finish, start) + 1) * 86_400

  defp span_seconds(%{start_time: %DateTime{} = start, end_time: %DateTime{} = finish}),
    do: max(DateTime.diff(finish, start), 0)

  defp span_seconds(_event), do: 0

  # An override that moves an occurrence without saying when it ends keeps
  # the series' length.
  defp override_with_end(%{start_time: %DateTime{} = start} = change, span)
       when not is_map_key(change, :end_time),
       do: Map.put(change, :end_time, DateTime.add(start, span, :second))

  defp override_with_end(%{start_time: %Date{} = start} = change, span)
       when not is_map_key(change, :end_time),
       do: Map.put(change, :end_time, Date.add(start, div(span, 86_400) - 1))

  defp override_with_end(change, _span), do: change

  # Whether the rule makes the occurrence an override's key names.
  defp slot_exists?(master, key, zone) do
    case slot_start(key, zone) do
      nil ->
        false

      slot ->
        master
        |> RecurrenceExpander.expand(slot, slot_end(slot))
        |> Enum.any?(&(occurrence_key(&1.start_time) == key))
    end
  end

  defp slot_start(<<_::binary-size(8)>> = key, _zone) do
    case Date.from_iso8601(
           binary_part(key, 0, 4) <>
             "-" <> binary_part(key, 4, 2) <> "-" <> binary_part(key, 6, 2)
         ) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp slot_start(key, zone) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(timed_key_to_iso(key)),
         {:ok, datetime} <- DateTime.from_naive(naive, zone) do
      datetime
    else
      _ -> nil
    end
  end

  defp timed_key_to_iso(
         <<y::binary-size(4), m::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           mi::binary-size(2), sec::binary-size(2)>>
       ),
       do: "#{y}-#{m}-#{d}T#{h}:#{mi}:#{sec}"

  defp timed_key_to_iso(_key), do: "invalid"

  defp slot_end(%Date{} = date), do: date
  defp slot_end(%DateTime{} = datetime), do: DateTime.add(datetime, 1, :second)

  defp in_zone(%DateTime{} = datetime, zone) do
    case DateTime.shift_zone(datetime, zone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end

  defp in_zone(other, _zone), do: other

  defp occurrence_key(%DateTime{} = start), do: Calendar.strftime(start, "%Y%m%dT%H%M%S")
  defp occurrence_key(%Date{} = start), do: Calendar.strftime(start, "%Y%m%d")

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
      provider_event_id: Map.get(raw, :provider_event_id),
      provider_metadata: Map.get(raw, :provider_metadata, %{}),
      timezone: Map.get(raw, :timezone),
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
      attendees: Enum.map(Map.get(raw, :attendees) || [], &Attendee.normalise/1),
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
