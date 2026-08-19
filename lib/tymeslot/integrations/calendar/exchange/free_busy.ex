defmodule Tymeslot.Integrations.Calendar.Exchange.FreeBusy do
  @moduledoc """
  Reads busy intervals out of a `GetUserAvailability` response.

  This is the source of truth for Exchange busy time. The item path
  (`FindItem` over a `CalendarView`, then `GetItem`) cannot see a recurring
  series' later occurrences on every server: a grommunio mailbox answers one
  `RecurringMaster` dated to the first occurrence, and nothing at all for a
  window covering later ones, so an organiser booked every morning reads as
  free. `GetUserAvailability` expands the series, so it decides availability
  and the item path feeds the dashboard grid.

  The intervals carry no identity: no item id, no subject, no change key. That
  is why this module answers plain maps rather than `CalendarEvent` structs,
  and why a caller that persists them has to synthesise its own stable uid.

  ## An unusable response is an error, never an empty list

  A `t:TimeZone` block that is missing or incomplete makes the server answer
  an empty body: no SOAP fault, no response message, no response code. Read as
  `{:ok, []}`, that says the mailbox is free all week, which is the worst
  answer this provider can give and the failure mode every decision here is
  shaped around. An absent response code is therefore an error in its own
  right, and so is a response code that is not `NoError`.

  `Requests.get_user_availability/3` asks for one mailbox, so one
  `m:FreeBusyResponse` comes back and its response code decides the call. A
  document carrying more than one is rejected rather than read: the reads
  below are document-wide, and `Soap.text/2` casts a nodeset to a string by
  concatenating it, so two mailboxes yield a response code of, say,
  `"NoErrorErrorAccessDenied"`, which is not `NoError`. That is the direction
  to fail in, since the alternative pairs one mailbox's response code with
  everybody's events, and it is stated here because nothing in the code says
  it.

  The same reasoning covers the view the server granted: `MergedOnly` and
  `None` are answered with a success code and no `t:CalendarEventArray`, so
  they too are errors rather than an empty calendar.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  require Logger

  @typedoc """
  One stretch of the mailbox's time that a booking must not overlap.

  `busy_type` records why it is blocked rather than gating anything: every
  value present here consumes the organiser's time.
  """
  @type interval :: %{start_at: DateTime.t(), end_at: DateTime.t(), busy_type: atom()}

  @type error_reason ::
          :no_response_code | {:response_code, String.t()} | {:free_busy_view_type, String.t()}

  # `Free` and `NoData` are the only values that leave the organiser bookable.
  # Anything else consumes time, and an unrecognised value is deliberately
  # read as busy rather than dropped: over-blocking costs a bookable slot,
  # under-blocking causes a double booking.
  #
  # `NoData` parts company with `Exchange.EventNormaliser`, which blocks on it
  # when reading an item's `LegacyFreeBusyStatus`. The divergence is meant:
  # there the value is a status the organiser put on a meeting that exists,
  # while in a free/busy expansion it means the server knows nothing about
  # that stretch of the window, which is not a booking.
  @free_types ["Free", "NoData"]
  @busy_types %{"Busy" => :busy, "Tentative" => :tentative, "OOF" => :out_of_office}

  # The rungs below `FreeBusy`, which EWS drops to when the caller's rights do
  # not reach the view the request asked for. `MergedOnly` answers a merged
  # bitmask string and `None` answers that nothing is available; neither
  # carries a `t:CalendarEventArray`, and both arrive with a response code of
  # `NoError`, so reading the events without reading the granted view answers
  # `{:ok, []}` for a booked mailbox under a success code.
  @unusable_views ["None", "MergedOnly"]

  @doc """
  Extracts every busy interval from a parsed `GetUserAvailability` response.

  Intervals arrive in the order the server listed them, which is chronological
  on every server seen so far but is not relied on here.
  """
  @spec parse_intervals(Soap.document()) :: {:ok, [interval()]} | {:error, error_reason()}
  def parse_intervals(doc) do
    # Spelled out rather than taken from `Soap.response_messages/2`, which
    # looks under an `m:ResponseMessages` wrapper this operation does not have
    # and would answer `[]` for every response, successful ones included.
    case Soap.text(doc, ~x"//m:FreeBusyResponse/m:ResponseMessage/m:ResponseCode/text()") do
      nil -> {:error, :no_response_code}
      "NoError" -> granted_view(doc)
      code -> {:error, {:response_code, code}}
    end
  end

  # The response echoes the view the server actually granted, which is
  # routinely lower than the one asked for: the probed server answers
  # `FreeBusy` to a `Detailed` request. `FreeBusy` and `Detailed` both carry
  # the intervals; the two rungs below them do not.
  #
  # An absent element is read as a granted view rather than as a failure. By
  # this point the server has stated `NoError` in a well-formed response
  # message, so it is talking to us properly and omitting an element the
  # schema requires; refusing to read the intervals it did send would turn a
  # working setup into a hard error, and the shape this guard exists to catch
  # names itself rather than staying silent.
  defp granted_view(doc) do
    case Soap.text(doc, ~x"//m:FreeBusyView/t:FreeBusyViewType/text()") do
      view when view in @unusable_views -> {:error, {:free_busy_view_type, view}}
      _view -> {:ok, intervals(doc)}
    end
  end

  # Three outcomes rather than the two `Exchange.FolderDiscovery` splits on: an
  # interval to keep, a free one that is a correct drop, and an unreadable one
  # that is an anomaly. Only the last is counted out of the dropped half.
  defp intervals(doc) do
    {read, dropped} =
      doc
      |> Soap.xpath(~x"//m:FreeBusyView/t:CalendarEventArray/t:CalendarEvent"l)
      |> Enum.map(&interval/1)
      |> Enum.split_with(&match?({:ok, _interval}, &1))

    log_unreadable(Enum.count(dropped, &(&1 == :unreadable)))

    Enum.map(read, fn {:ok, interval} -> interval end)
  end

  # Without an `else`, the `with` hands back whichever clause did not match, so
  # a free interval and an unreadable one stay distinguishable: the first is a
  # correct drop and the second is an anomaly worth logging.
  defp interval(event) do
    with {:ok, busy_type} <- busy_type(Soap.text(event, ~x"./t:BusyType/text()")),
         {:ok, start_at} <- to_datetime(Soap.text(event, ~x"./t:StartTime/text()")),
         {:ok, end_at} <- to_datetime(Soap.text(event, ~x"./t:EndTime/text()")) do
      {:ok, %{start_at: start_at, end_at: end_at, busy_type: busy_type}}
    end
  end

  # An omitted `t:BusyType` falls through to the second clause and blocks, for
  # the same reason an unrecognised one does.
  defp busy_type(type) when type in @free_types, do: :free
  defp busy_type(type), do: {:ok, Map.get(@busy_types, type, :busy)}

  defp to_datetime(nil), do: :unreadable

  # The order is load-bearing, and so is naming `:missing_offset` rather than
  # widening the clause to every error. `NaiveDateTime.from_iso8601/1` accepts
  # an offset-bearing value and silently discards the offset, reading
  # `2026-11-02T09:00:00-05:00` as `~N[2026-11-02 09:00:00]`, which would
  # anchor busy time five hours wrong. Trying `DateTime` first is what keeps
  # the fallback to genuinely unqualified values, and naming the one error it
  # answers for them says that the fallback is for that case alone.
  defp to_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, :missing_offset} -> from_unqualified(value)
      {:error, _reason} -> :unreadable
    end
  end

  # A `CalendarEvent` boundary is rendered in the zone the request named, and
  # servers disagree about saying so: grommunio suffixes `Z`, Exchange sends
  # the bare local time. That zone is UTC by construction, since
  # `Requests.get_user_availability/3` sends a bias of zero, so an unqualified
  # boundary is a UTC one. Rejecting it instead would drop every interval a
  # real Exchange server sends and report a booked mailbox as free.
  #
  # That reads the request only. It also bets that the server honours the EWS
  # contract, under which the request's `t:TimeZone` governs the times in the
  # answer as well; one that ignored it would mis-anchor every interval by its
  # own offset. The bet is not new, since the `Z` path above trusts the
  # server's zone claim exactly as far.
  defp from_unqualified(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} ->
        {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)}

      {:error, _reason} ->
        :unreadable
    end
  end

  # A dropped interval is busy time that vanishes from the diary, so the drop
  # is stated rather than left silent. Only the count travels: the boundaries
  # are the mailbox owner's data.
  defp log_unreadable(0), do: :ok

  defp log_unreadable(count) do
    Logger.warning("Skipping Exchange busy intervals carrying no readable boundary",
      provider: :exchange,
      count: count
    )
  end
end
