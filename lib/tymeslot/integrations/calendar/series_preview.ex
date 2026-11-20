defmodule Tymeslot.Integrations.Calendar.SeriesPreview do
  @moduledoc """
  The occurrences of a series the calendar has just written, shown before any
  sync has cached them.

  A repeating event made in the calendar, or an event given a repeat rule
  there, is cached at once as one row standing in for the whole series; its
  occurrences reach the cache only with the next sync. Until then a read of
  the cache would show the series on its first date alone and leave every
  later week empty. `add/4` computes those occurrences from the row at read
  time, through the expansion the sync itself uses
  (`ICalNormaliser.Expansion`), in the zone the series was written in. They
  are never stored.

  A previewed occurrence is the series' row with the occurrence's timing,
  its `preview_of` the row itself and its `preview_key` the slot's key. On
  the CalDAV family (and the debug calendar) that is the key the sync will
  cache the occurrence under, after the series' UID; Google and Outlook
  cache each occurrence under an id of the provider's own, so there it only
  tells the previews apart. The row's own slot is left out, since the row is
  drawn there. As soon as a sync caches any occurrence of the series,
  nothing more is previewed (`ProviderCalendarSeriesQueries.list_unsynced_series/4`),
  and the sync drops the row (`Tymeslot.Integrations.Calendar.Sync`), so no
  slot is ever drawn twice.

  The booking page needs none of this: it reads each calendar live, and the
  provider already expands the series it holds.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ICalNormaliser.Expansion
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarSeriesQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Profiles

  @doc """
  `rows`, read from the cache for `[range_start, range_end)` and the
  integrations `integration_ids`, with the previewed occurrences in that
  range of every series of theirs no sync has cached yet, ordered by start.

  ## Options

    * `:visibility_rules`, `:except_role` - as
      `ProviderCalendarSeriesQueries.list_unsynced_series/4` takes them, to
      match the read `rows` came from.
    * `:timed_only` - leave out all-day series.
  """
  @spec add(
          [ProviderCalendarEventSchema.t()],
          [integer()],
          {DateTime.t(), DateTime.t()},
          keyword()
        ) ::
          [ProviderCalendarEventSchema.t()]
  def add(rows, integration_ids, {range_start, range_end}, opts \\ []) do
    case occurrences(integration_ids, {range_start, range_end}, opts) do
      [] -> rows
      previews -> Enum.sort_by(rows ++ previews, &start_key/1, DateTime)
    end
  end

  @doc """
  The previewed occurrences alone, as `add/4` would add them.
  """
  @spec occurrences([integer()], {DateTime.t(), DateTime.t()}, keyword()) ::
          [ProviderCalendarEventSchema.t()]
  def occurrences(integration_ids, {range_start, range_end}, opts \\ []) do
    timed_only? = Keyword.get(opts, :timed_only, false)

    integration_ids
    |> ProviderCalendarSeriesQueries.list_unsynced_series(range_end, providers(), opts)
    |> Enum.reject(fn {row, _user_id} -> timed_only? and row.all_day end)
    |> with_zones()
    |> Enum.flat_map(fn {row, zone} -> expand(row, zone, range_start, range_end) end)
  end

  @doc """
  The previewed occurrences an availability read of the cache over
  `[range_start, range_end)` adds to `CalendarEventQueries.in_range/3`, as
  `CalendarEvent` structs: rows that may block only, from the calendars
  `blocking_rules` lets block.
  """
  @spec blocking_events([integer()], {DateTime.t(), DateTime.t()}, map()) :: [CalendarEvent.t()]
  def blocking_events(integration_ids, range, blocking_rules) do
    integration_ids
    |> occurrences(range, visibility_rules: blocking_rules, except_role: EventRole.display_only())
    |> Enum.map(&ProviderCalendarEventSchema.to_calendar_event/1)
  end

  @doc "Whether `event` is an occurrence previewed by `add/4`."
  @spec preview?(map()) :: boolean()
  def preview?(%{preview_of: %{}}), do: true
  def preview?(_event), do: false

  @doc """
  The series a previewed occurrence belongs to, as its cached row; any other
  event is returned as it is.
  """
  @spec series(map()) :: map()
  def series(%{preview_of: %{} = series}), do: series
  def series(event), do: event

  # Zones are read once per user: usually there is one.
  defp with_zones(rows_with_users) do
    zones =
      rows_with_users
      |> Enum.map(fn {_row, user_id} -> user_id end)
      |> Enum.uniq()
      |> Map.new(&{&1, Profiles.get_user_timezone(&1)})

    Enum.map(rows_with_users, fn {row, user_id} ->
      {row, written_zone(row.timezone, Map.get(zones, user_id))}
    end)
  end

  # The calendar writes a series in the organiser's zone and records it on
  # the row (`NewEvent`, `EventEdit`); a row without one is read in the
  # organiser's zone as it is now.
  defp written_zone(zone, organiser_zone) when is_binary(zone) and zone != "",
    do: if(valid_zone?(zone), do: zone, else: organiser_zone)

  defp written_zone(_zone, organiser_zone), do: organiser_zone

  defp valid_zone?(zone), do: match?({:ok, _now}, DateTime.now(zone))

  defp expand(%ProviderCalendarEventSchema{} = row, zone, range_start, range_end) do
    raw = %{
      uid: row.uid,
      recurrence_rule: row.recurrence_rule,
      start_time: if(row.all_day, do: row.start_date, else: row.start_at),
      end_time: if(row.all_day, do: row.end_date, else: row.end_at),
      timezone: zone,
      exdates: row.recurrence_exceptions || []
    }

    [raw]
    |> Expansion.expand_all(range_start, range_end)
    |> Enum.filter(&Map.get(&1, :_recurring))
    |> Enum.reject(&own_slot?(&1, row))
    |> Enum.map(&occurrence(&1, row))
  end

  defp own_slot?(%{_occ_start: %Date{} = start}, %{start_date: start_date}),
    do: Date.compare(start, start_date) == :eq

  defp own_slot?(%{_occ_start: %DateTime{} = start}, %{start_at: %DateTime{} = start_at}),
    do: DateTime.compare(start, start_at) == :eq

  defp own_slot?(_occurrence, _row), do: false

  defp occurrence(%{_occ_start: %Date{} = start, _occ_end: finish} = raw, row),
    do: %{
      row
      | start_date: start,
        end_date: finish,
        preview_of: row,
        preview_key: raw._uid_suffix
    }

  defp occurrence(%{_occ_start: start, _occ_end: finish} = raw, row),
    do: %{
      row
      | start_at: in_utc(start),
        end_at: in_utc(finish),
        preview_of: row,
        preview_key: raw._uid_suffix
    }

  defp in_utc(%DateTime{} = datetime) do
    utc = DateTime.shift_zone!(datetime, "Etc/UTC")
    %{utc | microsecond: {elem(utc.microsecond, 0), 6}}
  end

  defp start_key(%{all_day: true, start_date: %Date{} = date}),
    do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp start_key(%{start_at: %DateTime{} = start_at}), do: start_at
  defp start_key(_row), do: ~U[0000-01-01 00:00:00Z]

  # The providers the calendar writes repeat rules to, as the cache spells
  # them; Exchange and subscriptions are not among them.
  # Read whether or not the provider is enabled now: a row cached while it was
  # is still on the calendar.
  defp providers do
    Enum.filter(
      ProviderConfig.caldav_based_provider_strings() ++ ~w(google outlook debug),
      &ProviderConfig.writes_repeat_rules?/1
    )
  end
end
