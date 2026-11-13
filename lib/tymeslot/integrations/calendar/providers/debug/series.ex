defmodule Tymeslot.Integrations.Calendar.DebugCalendarProvider.Series do
  @moduledoc """
  The debug calendar's repeating events, kept the way a CalDAV server keeps
  a series: one iCalendar document per series (`:raw_ical` on its stored
  entry), addressed as `debug:<uid>` (`href/1`).

  Every write of part of a series is the CalDAV family's own rewrite of that
  document (`ICalBuilder.Series`: `exclude_occurrence/3`, `put_override/5`,
  `edit_master/5`, `split/5`), answered in the shapes the CalDAV writer
  answers (`CalDAV.SeriesWrites`), and every read parses the document with
  `ICalParser` and expands it with `ICalNormaliser`, as the CalDAV sync and
  live availability read do. So the debug calendar behaves exactly as a
  CalDAV calendar towards the grid's domain without a second implementation
  of the series semantics to drift from it.

  A repeating event stored as a plain map (by `DebugStore.put_event/1` from a
  test or the interactive dev calendar) is built into its document the first
  time it is read or written, as a CalDAV create builds one
  (`ICalBuilder.build_simple_event/3`), in its `:timezone`.
  """

  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series, as: SeriesDocument
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.ICalParser

  # How far before a range an occurrence may start and still overlap it. An
  # occurrence longer than this that starts before the range is skipped.
  @reach_seconds 7 * 86_400

  @typedoc "A scoped write or delete, as `SeriesEdit` and `EventDeletion` address one."
  @type occurrence :: %{
          required(:href) => String.t(),
          required(:key) => String.t(),
          optional(:scope) => :this_only | :following | :all,
          optional(:changes) => map(),
          optional(:timezone) => String.t() | nil
        }

  @doc "Where a debug series is addressed, as a CalDAV resource is by its href."
  @spec href(String.t()) :: String.t()
  def href(uid), do: "debug:#{uid}"

  @doc "The uid a series address names, or nil for anything else."
  @spec uid(term()) :: String.t() | nil
  def uid("debug:" <> uid), do: uid
  def uid(_other), do: nil

  @doc "Whether an event payload or stored map repeats."
  @spec repeating?(map()) :: boolean()
  def repeating?(%{recurrence_rule: rule}) when is_binary(rule) and rule != "", do: true
  def repeating?(_event), do: false

  @doc """
  The stored entry in the form the debug calendar keeps it: a repeating
  event as its document, anything else as it is.
  """
  @spec stored_form(map()) :: map()
  def stored_form(%{raw_ical: document} = entry) when is_binary(document), do: entry

  def stored_form(%{uid: uid} = entry) do
    if repeating?(entry) do
      %{
        uid: uid,
        raw_ical: build(uid, entry),
        provider_calendar_id: Map.get(entry, :provider_calendar_id),
        created_by_tymeslot: Map.get(entry, :created_by_tymeslot, true)
      }
    else
      entry
    end
  end

  # A series keeps the wall clock of its zone, so it is written in that zone
  # (`TimeZoneComponent.series_zone/1` ignores one it cannot resolve).
  defp build(uid, event) do
    zone = Map.get(event, :series_timezone) || Map.get(event, :timezone)
    ICalBuilder.build_simple_event(uid, Map.put(event, :series_timezone, zone))
  end

  @doc """
  A whole-event write of the series `entry` holds: its document patched
  property by property, as CalDAV patches a synced event.
  """
  @spec patch(map(), map()) :: map()
  def patch(%{raw_ical: document} = entry, event_data),
    do: %{entry | raw_ical: ICalBuilder.patch_event_properties(document, event_data)}

  @doc """
  Writes one occurrence, every occurrence, or one and every following one of
  the series `occurrence.href` names, answering as
  `CalDAV.SeriesWrites.update_occurrence/4`, `update_series/4` and
  `split_series/4` do: `{:ok, %{document: document}}`, plus the tail's
  `%{uid, href, document}` for a split. A series edited from its first
  occurrence onward is an edit of every occurrence.
  """
  @spec write(occurrence()) ::
          {:ok, %{required(:document) => String.t(), optional(:tail) => map()}}
          | {:error, term()}
  def write(%{href: href, scope: scope} = occurrence) do
    with {:ok, entry} <- fetch(uid(href)) do
      changes = Map.get(occurrence, :changes, %{})
      write(scope, entry, occurrence.key, changes, Map.get(occurrence, :timezone))
    end
  end

  defp write(:this_only, entry, key, changes, zone),
    do: keep(entry, SeriesDocument.put_override(entry.raw_ical, key, changes, zone))

  defp write(:all, entry, key, changes, zone),
    do: keep(entry, SeriesDocument.edit_master(entry.raw_ical, key, changes, zone))

  defp write(:following, entry, key, changes, zone) do
    case SeriesDocument.split(entry.raw_ical, key, changes, zone) do
      {:ok, %{head: head, tail: tail, tail_uid: tail_uid}} ->
        DebugStore.put_event(%{entry | uid: tail_uid, raw_ical: tail})
        DebugStore.put_event(%{entry | raw_ical: head})
        {:ok, %{document: head, tail: %{uid: tail_uid, href: href(tail_uid), document: tail}}}

      :first_occurrence ->
        write(:all, entry, key, changes, zone)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes one occurrence of the series `occurrence.href` names, answering as
  `CalDAV.SeriesWrites.delete_occurrence/4` does: `{:ok, %{document:
  document}}` with the series' new document, or `nil` when nothing of it is
  left (or it was already gone).
  """
  @spec delete(occurrence()) :: {:ok, %{document: String.t() | nil}}
  def delete(%{href: href, key: key} = occurrence) do
    with {:ok, entry} <- fetch(uid(href)),
         {:ok, document} <-
           SeriesDocument.exclude_occurrence(entry.raw_ical, key, Map.get(occurrence, :timezone)) do
      DebugStore.put_event(%{entry | raw_ical: document})
      {:ok, %{document: document}}
    else
      :empty ->
        DebugStore.delete_event(uid(href))
        {:ok, %{document: nil}}

      {:error, :not_found} ->
        {:ok, %{document: nil}}
    end
  end

  defp fetch(uid) when is_binary(uid) do
    case DebugStore.fetch_event(uid) do
      {:ok, entry} -> as_series(stored_form(entry))
      :error -> {:error, :not_found}
    end
  end

  defp fetch(_no_uid), do: {:error, :not_found}

  defp as_series(%{raw_ical: _document} = entry), do: {:ok, entry}
  defp as_series(_one_off), do: {:error, :not_found}

  defp keep(entry, {:ok, document}) do
    DebugStore.put_event(%{entry | raw_ical: document})
    {:ok, %{document: document}}
  end

  defp keep(_entry, {:error, reason}), do: {:error, reason}

  @doc """
  The series' `VEVENT`s as a CalDAV listing hands them over (parsed, each
  carrying the series' href and document), or `[]` when no occurrence of the
  series overlaps `[range_start, range_end)`, as a CalDAV time-range query
  leaves such a resource out.
  """
  @spec resource(map(), DateTime.t(), DateTime.t()) :: [map()]
  def resource(%{uid: uid, raw_ical: document}, range_start, range_end) do
    case ICalParser.parse(document) do
      {:ok, events} ->
        raw = Enum.map(events, &Map.merge(&1, %{href: href(uid), etag: nil, raw_ical: document}))

        if occurrences(raw, range_start, range_end) == [], do: [], else: raw

      {:error, _reason} ->
        []
    end
  end

  @doc """
  The occurrences of the series in `raw` (`resource/3`'s output) overlapping
  `[range_start, range_end)`, as the live busy-time check reads them
  (`ICalNormaliser.expand_occurrences/3`): timed ones in UTC, all-day ones
  with their dates and exclusive end.
  """
  @spec occurrences([map()], DateTime.t(), DateTime.t()) :: [map()]
  def occurrences(raw, range_start, range_end) do
    raw
    |> ICalNormaliser.expand_occurrences(
      DateTime.add(range_start, -@reach_seconds, :second),
      range_end
    )
    |> Enum.filter(&overlaps?(&1, range_start, range_end))
  end

  defp overlaps?(%{start_time: start} = occurrence, range_start, range_end) do
    finish = Map.get(occurrence, :end_time) || default_end(start)

    DateTime.compare(instant(start), range_end) == :lt and
      DateTime.compare(instant(finish), range_start) == :gt
  end

  defp default_end(%Date{} = date), do: Date.add(date, 1)
  defp default_end(datetime), do: datetime

  defp instant(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp instant(%DateTime{} = datetime), do: datetime
end
