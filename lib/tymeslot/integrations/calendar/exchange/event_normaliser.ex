defmodule Tymeslot.Integrations.Calendar.Exchange.EventNormaliser do
  @moduledoc """
  Turns the `CalendarItem` elements of a `GetItem` response into canonical
  `CalendarEvent` structs.

  Every field except the item id is treated as optional. This is not
  defensiveness for its own sake: a live server was observed silently dropping
  requested properties it does not implement rather than answering a fault, so
  a missing element carries no signal about whether the request was valid.

  One unusable item costs that item rather than the whole batch, matching the
  posture the CalDAV and ICS paths take: a single malformed event must not
  empty an organiser's diary. Dropping it is still data loss, so it raises the
  same `:invalid_calendar_event` operator alert those paths raise, which is
  the only thing that makes a quietly missing meeting visible.

  ## All-day events and the item's time zone

  EWS answers in UTC and this provider sends no `t:TimeZoneContext` header, but
  an all-day event is midnight to midnight in the *item's* own zone: a Berlin
  mailbox reports 3 September as `2026-09-02T22:00:00Z`, so reading the UTC
  date straight off that value misfiles the event everywhere east of Greenwich.

  `Requests.get_item/1` asks for `calendar:StartTimeZone`, which makes the day
  exact wherever the server answers it. Its `Id` attribute carries a *Windows*
  zone name ("W. Europe Standard Time"), so it goes through
  `Timezones.sanitize/1` for the CLDR mapping onto an IANA id.

  Servers that drop the property silently rather than faulting need a fallback,
  which anchors inside the local day: shifting the instant forward by `A` hours
  before taking the date lands on the intended day for every UTC offset in
  `(A-24, A]`, and is also correct when a server reports the boundary with an
  explicit offset rather than in UTC. No `A` is right everywhere, because
  inhabited offsets span 25 hours and any single anchor covers 24. `A` is
  thirteen hours, so the window is `(-11:00, +13:00]`: it reaches New Zealand
  year-round, and misfiles `-11:00`, `+13:45` and `+14:00`, which
  `StartTimeZone` gets right wherever a server provides it.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Timezones

  require Logger

  @type context :: %{
          calendar_integration_id: integer(),
          provider_calendar_id: String.t(),
          synced_at: DateTime.t()
        }

  # See the module doc on all-day events for why this number and not another.
  @all_day_anchor 13 * 60 * 60

  @doc """
  Returns the `CalendarItem` elements of a parsed `GetItem` response.

  A response message that did not succeed carries no `m:Items`, so it drops
  out of this walk structurally, and what comes back is exactly the readable
  items. Whether a batch that lost messages this way should be answered at all
  is `require_readable_batch/1`'s decision, not this walk's.
  """
  @spec parse_items(Soap.document()) :: [Soap.document()]
  def parse_items(doc) do
    Soap.xpath(doc, ~x"//m:GetItemResponseMessage/m:Items/t:CalendarItem"l)
  end

  @doc """
  States whether a `GetItem` batch may be read as an answer at all.

  `GetItem` answers one response message per requested id, so the guard
  `Exchange.ItemDiscovery` applies to `FindItem` — fail on the first stated
  failure — is the wrong shape here, and a partly successful batch is not an
  anomaly. The ids come from a *separate* round trip, so an item the organiser
  deleted between the two calls is answered with its own `ErrorItemNotFound`;
  failing the window over that would break the grid for the calendar every time
  someone deletes a meeting mid-sync, and permanently for a single item nobody
  can read.

  So a batch that lost only some of its messages is `:ok`, and the failed ones
  are logged under the server's own codes, with one exception: a batch in which
  *every* message failed is refused, because that is the emptied-calendar case
  the guard exists for and it is indistinguishable from an empty window
  otherwise. What this trades away is the partial case — an event denied on its
  own message disappears from the grid with only a log line to say so.
  Availability is unaffected either way: it comes from `GetUserAvailability`
  over the whole mailbox, never from these items.
  """
  @spec require_readable_batch(Soap.document()) :: :ok | {:error, Soap.failure()}
  def require_readable_batch(doc) do
    case Soap.response_messages(doc, "GetItemResponseMessage") do
      [] -> {:error, :no_response_messages}
      messages -> classify_batch(messages, Enum.reject(messages, &Soap.succeeded?/1))
    end
  end

  defp classify_batch(_messages, []), do: :ok

  defp classify_batch(messages, failed) when length(failed) == length(messages),
    do: {:error, {:response_code, Soap.response_code(hd(failed))}}

  # Only counts and the server's own codes travel: a failed message names no
  # item, and nothing else in the response is safe to log — a subject or a
  # location is mailbox content.
  defp classify_batch(_messages, failed) do
    Logger.warning("Exchange GetItem batch was partly unreadable",
      provider: :exchange,
      failed_item_count: length(failed),
      response_codes: failed |> Soap.response_codes() |> Enum.uniq() |> Enum.join(", ")
    )

    :ok
  end

  @doc """
  Normalises `CalendarItem` elements into `CalendarEvent` structs.

  Takes the list `parse_items/1` returns, which is the shape the `Provider`
  behaviour's `normalise_events/2` callback is defined over, rather than a
  whole document. Keeping the two steps apart lets a caller count what the
  response carried before any of it is dropped.
  """
  @spec normalise_events([Soap.document()], context()) :: {:ok, [CalendarEvent.t()]}
  def normalise_events(items, context) when is_list(items) do
    events =
      items
      |> Enum.map(&normalise_item(&1, context))
      |> Enum.reject(&is_nil/1)

    {:ok, events}
  end

  defp normalise_item(item, context) do
    attrs = extract(item, context)

    case CalendarEvent.new(attrs) do
      {:ok, event} ->
        event

      {:error, reason} ->
        # `attrs.uid` is nil exactly when the item carried neither a UID nor an
        # item id, which is itself one of the reasons an item is rejected.
        # `AlertTypes` renders this value straight into the operator's email,
        # so a blank one would arrive as "(event_id: )".
        uid = attrs.uid || "unknown"

        # A skipped item is silent data loss in the organiser's diary, so it
        # gets a warning and an operator alert rather than a debug line, which
        # is what the CalDAV and Google paths do with theirs. Only identifiers
        # and the reason travel: the subject, location and attendees are
        # mailbox content and must not reach a log line or an alert email.
        Logger.warning("Skipping unusable Exchange calendar item",
          calendar_integration_id: context.calendar_integration_id,
          event_uid: uid,
          reason: reason
        )

        AdminAlerts.send_alert(:invalid_calendar_event, %{
          provider: :exchange,
          event_uid: uid,
          reason: reason,
          calendar_integration_id: context.calendar_integration_id
        })

        nil
    end
  end

  defp extract(item, context) do
    item_id = Soap.text(item, ~x"./t:ItemId/@Id")
    all_day = Soap.text(item, ~x"./t:IsAllDayEvent/text()") == "true"

    base = %{
      uid: Soap.text(item, ~x"./t:UID/text()") || item_id,
      calendar_integration_id: context.calendar_integration_id,
      provider: :exchange,
      provider_calendar_id: context.provider_calendar_id,
      provider_event_id: item_id,
      synced_at: context.synced_at,
      summary: Soap.text(item, ~x"./t:Subject/text()"),
      location: Soap.text(item, ~x"./t:Location/text()"),
      etag: Soap.text(item, ~x"./t:ItemId/@ChangeKey"),
      all_day: all_day,
      status: map_status(Soap.text(item, ~x"./t:IsCancelled/text()")),
      transparency: map_transparency(Soap.text(item, ~x"./t:LegacyFreeBusyStatus/text()")),
      provider_metadata: metadata(item)
    }

    Map.merge(base, timing(item, all_day))
  end

  defp timing(item, true) do
    # Both boundaries are read in the zone `t:StartTimeZone` names, which is
    # the only one `Requests.get_item/1` asks for. An all-day event does not
    # cross zones, so the end boundary reusing it is not an approximation.
    zone = start_zone(item)

    %{
      start_date: to_all_day_date(Soap.text(item, ~x"./t:Start/text()"), zone),
      end_date: to_all_day_date(Soap.text(item, ~x"./t:End/text()"), zone)
    }
  end

  defp timing(item, false) do
    %{
      start_at: to_datetime(Soap.text(item, ~x"./t:Start/text()")),
      end_at: to_datetime(Soap.text(item, ~x"./t:End/text()"))
    }
  end

  # A cancelled item must stop blocking: `CalendarEvent.blocking?/1` honours
  # `:cancelled`, and every other provider maps its own cancellation flag the
  # same way. A server that does not implement `IsCancelled` omits it, which
  # reads back as nil and leaves the event confirmed.
  defp map_status("true"), do: :cancelled
  defp map_status(_other), do: :confirmed

  # `Free` is the only status that does not consume the organiser's time.
  # `Tentative`, `Busy`, `OOF`, `WorkingElsewhere` and `NoData` all block,
  # matching how the Google and Outlook normalisers treat their equivalents.
  defp map_transparency("Free"), do: :transparent
  defp map_transparency(_other), do: :opaque

  # Recorded because it is the only signal distinguishing a single item from an
  # expanded occurrence of a series, which the recurrence work will need.
  defp metadata(item) do
    case Soap.text(item, ~x"./t:CalendarItemType/text()") do
      nil -> %{}
      type -> %{"calendar_item_type" => type}
    end
  end

  # An omitted boundary reads back as nil and leaves the field unset, which is
  # what makes `CalendarEvent.new/1` reject the item.
  defp to_datetime(nil), do: nil

  defp to_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  # The `Id` attribute is a Windows zone name, not an IANA one, so it goes
  # through the shared sanitiser that owns the CLDR mapping. A server that
  # omits the element yields nil, which sanitises to nil and leaves the anchor
  # as the only path.
  defp start_zone(item) do
    item |> Soap.text(~x"./t:StartTimeZone/@Id") |> Timezones.sanitize()
  end

  defp to_all_day_date(value, zone) do
    case to_datetime(value) do
      nil -> nil
      datetime -> all_day_date(datetime, zone)
    end
  end

  # The exact route. An unrecognised zone name falls through to the anchor
  # exactly as an absent one does: the sanitiser passes anything it cannot map
  # through unchanged, so this is the only place that finds out whether the
  # name names a real zone.
  defp all_day_date(datetime, zone) when is_binary(zone) do
    case DateTime.shift_zone(datetime, zone) do
      {:ok, shifted} -> DateTime.to_date(shifted)
      {:error, _reason} -> anchored_date(datetime)
    end
  end

  defp all_day_date(datetime, nil), do: anchored_date(datetime)

  # The degraded route, for a server that named no zone. See the module doc on
  # all-day events for which offsets the anchor reaches and which it misfiles.
  defp anchored_date(datetime) do
    datetime |> DateTime.add(@all_day_anchor, :second) |> DateTime.to_date()
  end
end
