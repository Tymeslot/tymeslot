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
  empty an organiser's diary.

  ## All-day events and the item's time zone

  EWS answers in UTC unless the request carries a `t:TimeZoneContext` header,
  and this provider sends none. An all-day event is midnight to midnight in
  the *item's* own zone, so a mailbox in Berlin reports 3 September as
  `2026-09-02T22:00:00Z`, and reading the UTC date straight off that value
  would file the event on the wrong day everywhere east of Greenwich.

  `Requests.get_item/1` asks for `calendar:StartTimeZone`, and where the server
  answers it the day is exact: the instant is shifted into the item's own zone
  and the date read off there. Its `Id` attribute carries a *Windows* zone name
  ("W. Europe Standard Time"), so it goes through `Timezones.sanitize/1` for
  the CLDR mapping onto an IANA id.

  Servers that do not implement the property drop it silently rather than
  faulting, so a fallback is still needed. That fallback anchors inside the
  local day by shifting the instant forward twelve hours before taking the
  date, which is correct for every UTC offset in `-11:59..+12:00` and also when
  a server reports the boundary with an explicit offset rather than in UTC.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Timezones

  require Logger

  @type context :: %{
          calendar_integration_id: integer(),
          provider_calendar_id: String.t(),
          synced_at: DateTime.t()
        }

  # Half a day, in seconds. See the module doc on all-day events.
  @local_midday_anchor 12 * 60 * 60

  @doc """
  Normalises `CalendarItem` elements into `CalendarEvent` structs.

  Takes the list the `Provider` behaviour's `normalise_events/2` callback is
  defined over, not a whole document: extracting items from a `GetItem`
  response is the provider's job, and doing it there means an error response
  message (which carries no `m:Items`) drops out structurally rather than
  needing a response-code check here.
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
        # A skipped item is silent data loss in the organiser's diary, so it is
        # a warning rather than a debug line. Only the identifiers and the
        # reason are logged: the subject and location are mailbox content.
        Logger.warning("Skipping unusable Exchange calendar item",
          calendar_integration_id: context.calendar_integration_id,
          event_uid: attrs.uid,
          reason: reason
        )

        nil
    end
  end

  defp extract(item, context) do
    item_id = Soap.xpath(item, ~x"./t:ItemId/@Id"s)
    uid = Soap.xpath(item, ~x"./t:UID/text()"s)
    all_day = Soap.xpath(item, ~x"./t:IsAllDayEvent/text()"s) == "true"

    base = %{
      uid: presence(uid) || item_id,
      calendar_integration_id: context.calendar_integration_id,
      provider: :exchange,
      provider_calendar_id: context.provider_calendar_id,
      provider_event_id: presence(item_id),
      synced_at: context.synced_at,
      summary: presence(Soap.xpath(item, ~x"./t:Subject/text()"s)),
      location: presence(Soap.xpath(item, ~x"./t:Location/text()"s)),
      etag: presence(Soap.xpath(item, ~x"./t:ItemId/@ChangeKey"s)),
      all_day: all_day,
      status: status(Soap.xpath(item, ~x"./t:IsCancelled/text()"s)),
      transparency: transparency(Soap.xpath(item, ~x"./t:LegacyFreeBusyStatus/text()"s)),
      provider_metadata: metadata(item)
    }

    Map.merge(base, timing(item, all_day))
  end

  defp timing(item, true) do
    zone = item_zone(item)

    %{
      start_date: to_all_day_date(Soap.xpath(item, ~x"./t:Start/text()"s), zone),
      end_date: to_all_day_date(Soap.xpath(item, ~x"./t:End/text()"s), zone)
    }
  end

  defp timing(item, false) do
    %{
      start_at: to_datetime(Soap.xpath(item, ~x"./t:Start/text()"s)),
      end_at: to_datetime(Soap.xpath(item, ~x"./t:End/text()"s))
    }
  end

  # A cancelled item must stop blocking: `CalendarEvent.blocking?/1` honours
  # `:cancelled`, and every other provider maps its own cancellation flag the
  # same way. A server that does not implement `IsCancelled` omits it, which
  # reads back as `""` and leaves the event confirmed.
  defp status("true"), do: :cancelled
  defp status(_other), do: :confirmed

  # `Free` is the only status that does not consume the organiser's time.
  # `Tentative`, `Busy`, `OOF` and `WorkingElsewhere` all block, matching how
  # the Google and Outlook normalisers treat their equivalents.
  defp transparency("Free"), do: :transparent
  defp transparency(_other), do: :opaque

  # Recorded because it is the only signal distinguishing a single item from an
  # expanded occurrence of a series, which the recurrence work will need.
  defp metadata(item) do
    case presence(Soap.xpath(item, ~x"./t:CalendarItemType/text()"s)) do
      nil -> %{}
      type -> %{"calendar_item_type" => type}
    end
  end

  defp to_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  # The `Id` attribute is a Windows zone name, not an IANA one, so it goes
  # through the shared sanitiser that owns the CLDR mapping. A server that
  # omits the element yields `""`, which sanitises to nil and leaves the
  # anchor as the only path.
  defp item_zone(item) do
    item |> Soap.xpath(~x"./t:StartTimeZone/@Id"s) |> Timezones.sanitize()
  end

  defp to_all_day_date(value, zone) do
    case to_datetime(value) do
      nil -> nil
      datetime -> all_day_date(datetime, zone)
    end
  end

  defp all_day_date(datetime, nil) do
    datetime |> DateTime.add(@local_midday_anchor, :second) |> DateTime.to_date()
  end

  # An unrecognised zone name is treated exactly like an absent one: the
  # sanitiser passes anything it cannot map through unchanged, so this is the
  # only place that finds out whether the name names a real zone.
  defp all_day_date(datetime, zone) do
    case DateTime.shift_zone(datetime, zone) do
      {:ok, shifted} -> DateTime.to_date(shifted)
      {:error, _reason} -> all_day_date(datetime, nil)
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
