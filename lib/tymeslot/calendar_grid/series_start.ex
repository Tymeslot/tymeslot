defmodule Tymeslot.CalendarGrid.SeriesStart do
  @moduledoc """
  Where a series begins: the start of its first occurrence, which an edit of
  the whole series writes its repeat pattern against.

  A repeat pattern is anchored to a start (`Recurrence.Pattern`): a monthly
  series "on the start's day" names no day, a weekly one always includes the
  start's weekday. A rule written to a whole series is read against the
  series' own first start, never the start of the occurrence it was edited
  from, so that is the start a whole-series edit is built from.

  Each provider keeps it differently:

    * Google and Outlook: the master's start, cached beside the series' rule
      (`SeriesRules.with_series_start/1`).
    * The CalDAV family: the master `VEVENT`'s `DTSTART`, in the document
      cached on every occurrence.
    * An event with no series: its own start.

  A series whose first start is not known (a Google or Outlook series whose
  master has not been read) answers `nil`.
  """

  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesSplit, as: OutlookSeriesSplit
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Integrations.Calendar.SeriesRules

  @doc """
  The first start of the series `event` belongs to: a `Date` for an all-day
  series, a UTC `DateTime` otherwise, or `nil` when it is not known.
  """
  @spec of(map()) :: Date.t() | DateTime.t() | nil
  def of(event), do: start_of(event, &Occurrence.cached_row/1)

  @doc """
  `of/1` for `row`, the event's cached row already read, which is not read
  again.
  """
  @spec of_cached(map()) :: Date.t() | DateTime.t() | nil
  def of_cached(row), do: start_of(row, & &1)

  defp start_of(event, cached_row) do
    case Occurrence.series_family(event) do
      :single -> own_start(event)
      :caldav -> event |> cached_row.() |> caldav_start()
      :provider_ids -> provider_start(event)
      :unsupported -> nil
    end
  end

  @doc """
  Where the series put `event`, an occurrence of it: its original start,
  where a change of this and the following occurrences splits the series
  whether or not the occurrence was moved on its own since. A `Date` for an
  all-day series, a UTC `DateTime` otherwise; for an event of no series its
  own start; `nil` when it cannot be told.

  Google and Outlook state it (`Occurrence.original_start/1`); a CalDAV
  occurrence is cached under the key of its `RECURRENCE-ID`, a wall clock in
  the series' zone (`Occurrence.occurrence_key/1`).
  """
  @spec slot(map()) :: Date.t() | DateTime.t() | nil
  def slot(event), do: slot_of(event, &Occurrence.cached_row/1)

  @doc """
  `slot/1` for `row`, the event's cached row already read, which is not
  read again.
  """
  @spec slot_of_cached(map()) :: Date.t() | DateTime.t() | nil
  def slot_of_cached(row), do: slot_of(row, & &1)

  defp slot_of(event, cached_row) do
    case Occurrence.series_family(event) do
      :single -> own_start(event)
      :caldav -> event |> cached_row.() |> caldav_slot()
      :provider_ids -> event |> cached_row.() |> provider_slot()
      :unsupported -> nil
    end
  end

  defp provider_slot(row) do
    case Occurrence.original_start(row) do
      {:ok, start} -> fit(start, row)
      {:error, _unaddressable} -> nil
    end
  end

  defp caldav_slot(row) do
    with {:ok, key} <- Occurrence.occurrence_key(row),
         {:ok, wall} <- parse_key(key) do
      case wall do
        %Date{} = date -> date
        %NaiveDateTime{} = naive -> naive |> in_zone(series_zone(row)) |> fit(row)
      end
    else
      _unaddressable -> nil
    end
  end

  defp parse_key(<<date::binary-size(8)>>), do: Date.from_iso8601(iso_date(date))

  defp parse_key(<<date::binary-size(8), "T", time::binary-size(6), _rest::binary>>) do
    <<hh::binary-size(2), mm::binary-size(2), ss::binary-size(2)>> = time
    NaiveDateTime.from_iso8601("#{iso_date(date)}T#{hh}:#{mm}:#{ss}")
  end

  defp parse_key(_key), do: :error

  defp iso_date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>), do: "#{y}-#{m}-#{d}"

  # The zone the series' master names, which its keys are wall clocks in.
  defp series_zone(%{raw_ical: document}) when is_binary(document) do
    with {:ok, events} <- ICalParser.parse(document),
         %{timezone: zone} when is_binary(zone) <- Enum.find(events, &master?/1) do
      zone
    else
      _utc -> "Etc/UTC"
    end
  end

  defp series_zone(_row), do: "Etc/UTC"

  defp in_zone(naive, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> at
      {:ambiguous, first, _second} -> first
      {:gap, _before, after_gap} -> after_gap
      {:error, _reason} -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end

  @doc """
  How many occurrences `rule` makes from `first` up to, but not including,
  `boundary`, for a series on a calendar of `provider`, as a split of the
  series counts them off its `COUNT`. Outlook counts an absolute monthly
  or yearly series its own way (`Outlook.SeriesSplit.absolute_count_before/3`);
  every other calendar as RFC 5545 does (`RecurrenceExpander.count_before/3`).
  """
  @spec count_before(
          atom() | String.t() | nil,
          String.t(),
          Date.t() | DateTime.t(),
          Date.t() | DateTime.t()
        ) ::
          non_neg_integer()
  def count_before(provider, rule, first, boundary) do
    with "outlook" <- to_string(provider),
         {:ok, count} <-
           OutlookSeriesSplit.absolute_count_before(rule, date_of(first), date_of(boundary)) do
      count
    else
      _rfc_5545 -> RecurrenceExpander.count_before(rule, first, boundary)
    end
  end

  defp date_of(%DateTime{} = at), do: DateTime.to_date(at)
  defp date_of(%Date{} = date), do: date

  # A Google or Outlook master's own row carries the rule and is its first
  # start; an occurrence names its master in `recurring_event_id`.
  defp provider_start(event) do
    if is_nil(Map.get(event, :recurring_event_id)) do
      own_start(event)
    else
      case SeriesRules.with_series_start(event) do
        %{series_start: %DateTime{} = start} -> fit(start, event)
        _not_read -> nil
      end
    end
  end

  defp caldav_start(%{raw_ical: document} = row) when is_binary(document) do
    with {:ok, events} <- ICalParser.parse(document),
         %{start_time: start} <- Enum.find(events, &master?/1) do
      fit(start, row)
    else
      _no_master -> nil
    end
  end

  defp caldav_start(_row), do: nil

  defp master?(parsed),
    do: is_binary(parsed[:recurrence_rule]) and is_nil(parsed[:recurrence_id])

  defp own_start(%{all_day: true, start_date: %Date{} = date}), do: date
  defp own_start(%{start_at: %DateTime{} = start} = event), do: fit(start, event)
  defp own_start(_event), do: nil

  # An all-day series starts on a day; a master read as midnight UTC is
  # that day.
  defp fit(%DateTime{} = start, %{all_day: true}), do: DateTime.to_date(start)
  defp fit(%Date{} = start, %{all_day: true}), do: start
  defp fit(%DateTime{} = start, _event), do: DateTime.shift_zone!(start, "Etc/UTC")
  defp fit(%Date{} = start, _event), do: DateTime.new!(start, ~T[00:00:00], "Etc/UTC")
end
