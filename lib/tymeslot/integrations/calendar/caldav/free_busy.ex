defmodule Tymeslot.Integrations.Calendar.CalDAV.FreeBusy do
  @moduledoc """
  The RFC 4791 §7.10 `CALDAV:free-busy-query` REPORT, for a calendar shared
  with the account as busy times only (`CALDAV:read-free-busy` without
  `DAV:read`), which answers the `calendar-query` every other read sends with
  403.

  The server answers with one `VFREEBUSY` component listing `FREEBUSY`
  periods, as `start/end` or `start/duration`. Busy periods (`FBTYPE=BUSY`,
  the default, `BUSY-TENTATIVE` and `BUSY-UNAVAILABLE`) come back as events
  in the shape `XmlHandler.parse_calendar_query/1` gives, opaque and
  confirmed, so the availability read takes them as it takes any other
  calendar's; `FREE` periods are dropped. They carry no title or detail: the
  share grants none.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler
  alias Tymeslot.Integrations.Calendar.CalendarEvent

  # Cached periods carry a synthesised uid. The meeting reconciliation
  # resolves a vanished event to a Tymeslot meeting by uid, so the namespace
  # must be one no meeting or CalDAV event can produce: none admits a colon.
  @cached_uid_prefix "tymeslot:caldav-busy:"

  @busy_types ~w(BUSY BUSY-TENTATIVE BUSY-UNAVAILABLE)

  @doc """
  The REPORT body asking for the busy time between `start_time` and
  `end_time`.
  """
  @spec build_query(DateTime.t(), DateTime.t()) :: String.t()
  def build_query(start_time, end_time) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <c:free-busy-query xmlns:c="urn:ietf:params:xml:ns:caldav">
      <c:time-range start="#{stamp(start_time)}" end="#{stamp(end_time)}"/>
    </c:free-busy-query>
    """
  end

  @doc """
  The busy periods of a `VFREEBUSY` response from the calendar at
  `calendar_path`, as events. A period that does not parse is skipped.

  `{:error, :not_free_busy}` for a body holding no `VFREEBUSY` at all (a
  Multi-Status, a proxy's error page, nothing): that is not an answer saying
  the calendar is free, so the read fails closed on it.
  """
  @spec parse(String.t(), String.t()) ::
          {:ok, [XmlHandler.parsed_event()]} | {:error, :not_free_busy}
  def parse(body, calendar_path) when is_binary(body) do
    unfolded = unfold(body)

    if unfolded =~ ~r/^BEGIN:VFREEBUSY\r?$/m do
      events =
        unfolded
        |> String.split(~r/\r?\n/)
        |> Enum.flat_map(&busy_periods/1)
        |> Enum.map(&to_event(&1, calendar_path))

      {:ok, events}
    else
      {:error, :not_free_busy}
    end
  end

  # RFC 5545 §3.1: a line break followed by a space or tab continues the line.
  defp unfold(body), do: String.replace(body, ~r/\r?\n[ \t]/, "")

  defp busy_periods(line) do
    case Regex.run(~r/^FREEBUSY(;[^:]*)?:(.+)$/i, String.trim_trailing(line)) do
      [_line, params, periods] -> if busy?(params), do: parse_periods(periods), else: []
      [_line, periods] -> parse_periods(periods)
      nil -> []
    end
  end

  defp busy?(params) do
    case Regex.run(~r/;FBTYPE=([^;]+)/i, params) do
      nil -> true
      [_match, type] -> String.upcase(type) in @busy_types
    end
  end

  defp parse_periods(periods) do
    periods
    |> String.split(",")
    |> Enum.flat_map(fn period ->
      case parse_period(String.trim(period)) do
        {:ok, interval} -> [interval]
        :error -> []
      end
    end)
  end

  defp parse_period(period) do
    with [start, finish] <- String.split(period, "/", parts: 2),
         {:ok, start} <- parse_stamp(start),
         {:ok, finish} <- parse_end(start, finish),
         :gt <- DateTime.compare(finish, start) do
      {:ok, {start, finish}}
    else
      _unparseable -> :error
    end
  end

  defp parse_end(start, "P" <> _rest = duration) do
    case parse_duration(duration) do
      {:ok, seconds} -> {:ok, DateTime.add(start, seconds, :second)}
      :error -> :error
    end
  end

  defp parse_end(_start, finish), do: parse_stamp(finish)

  # Period stamps are UTC by RFC 5545 §3.8.2.6.
  defp parse_stamp(
         <<y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           "Z">>
       ) do
    with {:ok, date} <- Date.from_iso8601("#{y}-#{mo}-#{d}"),
         {:ok, time} <- Time.from_iso8601("#{h}:#{mi}:#{s}") do
      DateTime.new(date, time, "Etc/UTC")
    else
      _invalid -> :error
    end
  end

  defp parse_stamp(_other), do: :error

  @duration ~r/^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/

  defp parse_duration(duration) do
    case Regex.run(@duration, duration) do
      nil ->
        :error

      [_whole | parts] ->
        [weeks, days, hours, minutes, seconds] =
          parts |> Enum.concat(List.duplicate("", 5 - length(parts))) |> Enum.map(&to_int/1)

        {:ok, (((weeks * 7 + days) * 24 + hours) * 60 + minutes) * 60 + seconds}
    end
  end

  defp to_int(""), do: 0
  defp to_int(digits), do: String.to_integer(digits)

  # The end is part of the uid: the read dedupes on it, and two periods may
  # share a start (a tentative half hour inside an unavailable two hours).
  defp to_event({start, finish}, calendar_path) do
    %{
      uid:
        "freebusy:#{calendar_path}:#{DateTime.to_iso8601(start)}/#{DateTime.to_iso8601(finish)}",
      href: calendar_path,
      etag: nil,
      summary: nil,
      description: nil,
      location: nil,
      attendees: [],
      recurrence_rule: nil,
      recurrence_id: nil,
      exdates: [],
      start_time: start,
      end_time: finish,
      timezone: nil,
      floating: false,
      transparency: "opaque",
      status: "CONFIRMED",
      raw_ical: nil
    }
  end

  @doc """
  Busy periods `parse/2` read, as the `CalendarEvent`s the sync caches for
  the calendar at `calendar_path`: opaque, confirmed, and pointing at no
  provider event, so the grid never shows them (they are written
  `busy_only`) and nothing can resolve a deletion by them.
  """
  @spec to_cached_events([XmlHandler.parsed_event()], pos_integer(), String.t(), DateTime.t()) ::
          [CalendarEvent.t()]
  def to_cached_events(periods, calendar_integration_id, calendar_path, synced_at) do
    Enum.map(periods, fn %{start_time: start_at, end_time: end_at} ->
      CalendarEvent.new!(%{
        uid:
          @cached_uid_prefix <>
            Enum.join(
              [
                calendar_integration_id,
                calendar_path,
                DateTime.to_iso8601(start_at),
                DateTime.to_iso8601(end_at)
              ],
              "|"
            ),
        calendar_integration_id: calendar_integration_id,
        provider: :caldav,
        provider_calendar_id: calendar_path,
        provider_event_id: nil,
        synced_at: synced_at,
        all_day: false,
        start_at: start_at,
        end_at: end_at,
        transparency: :opaque,
        status: :confirmed
      })
    end)
  end

  defp stamp(datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y%m%dT%H%M%SZ")
end
