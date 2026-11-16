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
  the pure `DebugSchedule` generator; in-app events are stored verbatim, except
  that a repeating one is kept as the iCalendar document a CalDAV server would
  hold, and written, listed and expanded by the CalDAV family's own code
  (`DebugCalendarProvider.Series`), so the grid's scoped edits and deletes of a
  debug series behave exactly as they do on CalDAV. All store access tolerates
  the store not running: it runs on every dev server, in `:test` only when a
  test starts it, and reads then fall back to the default pattern (not an
  empty set).

  Only wired up in development/test via the `debug` integration provider.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider.Series
  alias Tymeslot.Integrations.Calendar.DebugSchedule
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.ICalNormaliser

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
    |> Series.stored_form()
    |> DebugStore.put_event()

    {:ok, CreatedEvent.new(uid)}
  end

  # A scoped edit of a series names it by its address and the occurrence by
  # its key, as `SeriesEdit` does for the CalDAV family, and is answered as
  # the CalDAV writer answers it; anything else is a whole-event write, which
  # patches a series' document as CalDAV patches a synced event.
  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(_client, _uid, %{occurrence: %{href: _href, key: _key, scope: _scope} = occ}),
    do: Series.write(occ)

  def update_event(_client, uid, event_data) do
    case DebugStore.fetch_event(uid) do
      {:ok, existing} ->
        DebugStore.put_event(patched(existing, event_data, uid))

      # A write for an event the store does not hold creates it when it says
      # when it is; a partial one would only be a half-event to overlap-check.
      :error
      when is_map_key(event_data, :start_time) and
             :erlang.map_get(:start_time, event_data) != nil ->
        DebugStore.put_event(Series.stored_form(stored_event_from(event_data, uid)))

      :error ->
        {:error, :not_found}
    end
  end

  defp patched(existing, event_data, uid) do
    case Series.stored_form(existing) do
      %{raw_ical: _document} = series -> Series.patch(series, event_data)
      event -> Series.stored_form(Map.merge(event, stored_event_from(event_data, uid)))
    end
  end

  # One occurrence is deleted (`opts[:occurrence]`) and answered as the
  # CalDAV writer answers it; otherwise the event, or the series its address
  # names, goes. The runtime hands a provider outside the CalDAV family its
  # `provider_event_id` as the id, so a series' address can arrive either way.
  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(_client, id, opts) do
    case opts[:occurrence] do
      %{href: _href, key: _key} = occurrence ->
        Series.delete(occurrence)

      _whole ->
        DebugStore.delete_event(Series.uid(opts[:provider_event_id]) || Series.uid(id) || id)
    end
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

    created = listed(Map.values(events), start_time, end_time)

    {:ok, generated ++ created}
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events_representation, do: :raw

  @impl Tymeslot.Integrations.Calendar.Provider
  def convert_events(events), do: events

  # A series' VEVENTs are expanded by the normaliser the CalDAV sync uses,
  # over the window every sync reads.
  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(raw_events, context) when is_list(raw_events) do
    {series, others} = Enum.split_with(raw_events, &Map.has_key?(&1, :raw_ical))
    {:ok, expanded} = ICalNormaliser.normalise_events(series, context, :debug)
    {:ok, Enum.map(others, &normalise_event(&1, context)) ++ expanded}
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
      :transparency,
      :provider_calendar_id,
      :timezone
    ])
    |> Map.put(:uid, uid)
    |> Map.put_new(:all_day, false)
    |> Map.put(:status, "confirmed")
    |> Map.put(:created_by_tymeslot, true)
  end

  @doc """
  The stored events overlapping `[range_start, range_end)` in the busy-block
  shape the interactive dev calendar reads: a one-off event as stored, and
  each occurrence of a repeating one as the live CalDAV busy-time check
  expands it (`DebugCalendarProvider.Series.occurrences/3`), timed ones in
  UTC and all-day ones by date with an exclusive end date, as the cache keeps
  them. All-day events are projected to day-spanning blocks for the overlap
  check but returned with their dates.
  """
  @spec stored_events_in_range(DateTime.t(), DateTime.t()) :: [map()]
  def stored_events_in_range(range_start, range_end) do
    DebugStore.snapshot().events
    |> Map.values()
    |> Enum.flat_map(&stored_in_range(Series.stored_form(&1), range_start, range_end))
  end

  defp stored_in_range(%{raw_ical: _document} = entry, range_start, range_end) do
    entry
    |> Series.resource(range_start, range_end)
    |> Series.occurrences(range_start, range_end)
    |> Enum.map(&busy_occurrence/1)
  end

  defp stored_in_range(event, range_start, range_end),
    do: Enum.filter([event], &overlaps?(&1, range_start, range_end))

  defp busy_occurrence(%{start_time: %Date{} = start} = occurrence) do
    finish = Map.get(occurrence, :end_time) || Date.add(start, 1)

    Map.merge(occurrence, %{
      all_day: true,
      end_time: Enum.max([Date.add(start, 1), finish], Date),
      status: "confirmed"
    })
  end

  defp busy_occurrence(occurrence),
    do: Map.merge(occurrence, %{all_day: false, status: "confirmed"})

  @doc "Where a debug series is addressed, as a CalDAV resource is by its href."
  @spec series_href(String.t()) :: String.t()
  defdelegate series_href(uid), to: Series, as: :href

  # The stored events as a listing hands them over: a series as the parsed
  # VEVENTs of its document, which `normalise_events/2` expands as the CalDAV
  # sync does, a one-off event as stored.
  defp listed(events, range_start, range_end) do
    Enum.flat_map(events, fn event ->
      case Series.stored_form(event) do
        %{raw_ical: _document} = series -> Series.resource(series, range_start, range_end)
        one_off -> Enum.filter([one_off], &overlaps?(&1, range_start, range_end))
      end
    end)
  end

  defp overlaps?(
         %{all_day: true, start_time: %Date{} = start_date} = event,
         range_start,
         range_end
       ) do
    # The end date is exclusive, as the cache keeps every all-day event.
    end_date = Enum.max([Map.get(event, :end_time, start_date), Date.add(start_date, 1)], Date)
    block_start = day_start(start_date)
    block_end = day_start(end_date)

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
      transparency: transparency(Map.get(raw, :transparency)),
      created_by_tymeslot: Map.get(raw, :created_by_tymeslot, false)
    }
  end

  # A grid write stores the cache's string; anything else, or nothing, is busy.
  defp transparency(value) when value in ["transparent", :transparent], do: :transparent
  defp transparency(_value), do: :opaque

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
