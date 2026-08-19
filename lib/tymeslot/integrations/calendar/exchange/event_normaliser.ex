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

  ## All-day events and the missing time zone

  EWS answers in UTC unless the request carries a `t:TimeZoneContext` header,
  and this provider sends none. An all-day event is midnight to midnight in
  the *item's* own zone, so a mailbox in Berlin reports 3 September as
  `2026-09-02T22:00:00Z`, and reading the UTC date straight off that value
  would file the event on the wrong day everywhere east of Greenwich.
  `BaseShape=Default` returns no time zone to correct it with, so the date is
  recovered by anchoring at local midday: shifting by twelve hours lands
  inside the intended day for every offset in `-11:59..+12:00`, which is every
  zone Exchange mailboxes realistically live in, and it is also correct when a
  server reports the boundary with an explicit offset rather than in UTC. The
  handful of zones past `+12:00` (Chatham, Samoa, Kiritimati) still land a day
  early; fixing those properly means requesting the item's zone rather than
  guessing at it.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

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

    # `status` is deliberately absent, leaving the struct's `:confirmed`
    # default. `BaseShape=Default` returns no cancellation flag, and a property
    # this provider does not request cannot be read back: Exchange drops
    # unsupported `AdditionalProperties` silently, so a branch keyed on one
    # would be unreachable rather than merely untested.
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
      transparency: transparency(Soap.xpath(item, ~x"./t:LegacyFreeBusyStatus/text()"s)),
      provider_metadata: metadata(item)
    }

    Map.merge(base, timing(item, all_day))
  end

  defp timing(item, true) do
    %{
      start_date: to_all_day_date(Soap.xpath(item, ~x"./t:Start/text()"s)),
      end_date: to_all_day_date(Soap.xpath(item, ~x"./t:End/text()"s))
    }
  end

  defp timing(item, false) do
    %{
      start_at: to_datetime(Soap.xpath(item, ~x"./t:Start/text()"s)),
      end_at: to_datetime(Soap.xpath(item, ~x"./t:End/text()"s))
    }
  end

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

  defp to_all_day_date(value) do
    case to_datetime(value) do
      nil -> nil
      datetime -> datetime |> DateTime.add(@local_midday_anchor, :second) |> DateTime.to_date()
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
