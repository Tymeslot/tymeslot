defmodule Tymeslot.Integrations.Calendar.Exchange.EventNormaliserTest do
  # async: false — capturing admin alerts swaps the global
  # `:admin_alerts_impl`, which application env makes visible to every other
  # process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import SweetXml, only: [sigil_x: 2]
  import Tymeslot.AdminAlertsCaptureHelpers

  @moduletag :integrations

  setup :capture_admin_alerts

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Exchange.EventNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  @context %{
    calendar_integration_id: 7,
    provider_calendar_id: "AAABBB==",
    synced_at: ~U[2026-08-19 09:00:00Z]
  }

  @timed_item """
  <t:CalendarItem>
    <t:ItemId Id="item-1" ChangeKey="ck-1"/>
    <t:Subject>Standup</t:Subject>
    <t:UID>040000008200E00074C5B7101A82E008</t:UID>
    <t:Start>2026-09-01T10:00:00Z</t:Start>
    <t:End>2026-09-01T11:00:00Z</t:End>
    <t:IsAllDayEvent>false</t:IsAllDayEvent>
    <t:LegacyFreeBusyStatus>Busy</t:LegacyFreeBusyStatus>
    <t:Location>Room 1</t:Location>
    <t:CalendarItemType>Single</t:CalendarItemType>
  </t:CalendarItem>
  """

  describe "normalise_events/2" do
    test "maps a timed event onto a CalendarEvent" do
      assert {:ok, [event]} = EventNormaliser.normalise_events(items([@timed_item]), @context)

      assert %CalendarEvent{} = event
      assert event.uid == "040000008200E00074C5B7101A82E008"
      assert event.provider == :exchange
      assert event.provider_event_id == "item-1"
      assert event.etag == "ck-1"
      assert event.calendar_integration_id == 7
      assert event.provider_calendar_id == "AAABBB=="
      assert event.summary == "Standup"
      assert event.location == "Room 1"
      assert event.all_day == false
      assert event.start_at == ~U[2026-09-01 10:00:00Z]
      assert event.end_at == ~U[2026-09-01 11:00:00Z]
      assert event.start_date == nil
      assert event.end_date == nil
      assert event.transparency == :opaque
      assert event.status == :confirmed
      assert event.provider_metadata == %{"calendar_item_type" => "Single"}
    end

    test "leaves the optional content fields nil when the server omits them" do
      item = """
      <t:CalendarItem>
        <t:ItemId Id="item-bare" ChangeKey="ck-bare"/>
        <t:UID>uid-bare</t:UID>
        <t:Start>2026-09-01T10:00:00Z</t:Start>
        <t:End>2026-09-01T11:00:00Z</t:End>
      </t:CalendarItem>
      """

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.uid == "uid-bare"
      assert event.summary == nil
      assert event.location == nil
      assert event.provider_metadata == %{}
      # No `IsAllDayEvent` means a timed event, not a discarded one.
      assert event.all_day == false
      assert event.start_at == ~U[2026-09-01 10:00:00Z]
    end

    test "maps an all-day event onto Date fields with no datetimes" do
      assert {:ok, [event]} =
               EventNormaliser.normalise_events(items([all_day_item("Z", "Z")]), @context)

      assert event.all_day == true
      assert event.start_date == ~D[2026-09-03]
      assert event.end_date == ~D[2026-09-04]
      assert event.start_at == nil
      assert event.end_at == nil
    end

    test "files an all-day event from a mailbox east of UTC on its own local days" do
      # A Berlin mailbox's 3 September all-day event reaches us as the previous
      # evening in UTC, because EWS answers in UTC and the day boundary is the
      # item's own. Reading the UTC date off it would file the event a day early.
      item = all_day_item("2026-09-02T22:00:00Z", "2026-09-03T22:00:00Z")

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.start_date == ~D[2026-09-03]
      assert event.end_date == ~D[2026-09-04]
    end

    test "files an all-day event reported with an explicit offset on its own local days" do
      item = all_day_item("2026-09-03T00:00:00+02:00", "2026-09-04T00:00:00+02:00")

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.start_date == ~D[2026-09-03]
      assert event.end_date == ~D[2026-09-04]
    end

    test "files an all-day event on its own local day across the offsets the anchor covers" do
      # The thirteen-hour anchor is exact for every UTC offset in
      # `(-11:00, +13:00]`. The two eastern entries are what the twelve-hour
      # anchor this replaced could not reach: Chatham in standard time, and
      # New Zealand's daylight time, which five million people keep for
      # roughly half the year.
      for offset <- ["-10:00", "-05:00", "+00:00", "+02:00", "+12:00", "+12:45", "+13:00"] do
        item = all_day_item("2026-09-03T00:00:00#{offset}", "2026-09-04T00:00:00#{offset}")

        assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)
        assert event.start_date == ~D[2026-09-03], "offset #{offset} start"
        assert event.end_date == ~D[2026-09-04], "offset #{offset} end"
      end
    end

    test "the anchor misfiles the offsets outside its window, which the item's zone fixes" do
      # Documented cost rather than desired behaviour. `-11:00` (Niue,
      # American Samoa, Midway) is what widening the window eastwards gave up;
      # `+13:45` (Chatham in daylight time) and `+14:00` (Kiritimati) are past
      # any anchor's reach, since inhabited offsets span 25 hours and an anchor
      # covers 24.
      misfiled = [
        {"-11:00", ~D[2026-09-04]},
        {"+13:45", ~D[2026-09-02]},
        {"+14:00", ~D[2026-09-02]}
      ]

      for {offset, filed_on} <- misfiled do
        item = all_day_item("2026-09-03T00:00:00#{offset}", "2026-09-04T00:00:00#{offset}")

        assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)
        assert event.start_date == filed_on, "offset #{offset}"
      end
    end

    test "reads the all-day date off the item's own zone when the server supplies one" do
      # Kiritimati is UTC+14, past the reach of any anchor, so this date can
      # only be right if `StartTimeZone` was honoured. Its `Id` is the Windows
      # name a real Exchange server sends, not an IANA one.
      item =
        all_day_item("2026-09-02T10:00:00Z", "2026-09-03T10:00:00Z",
          zone: "Line Islands Standard Time"
        )

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.start_date == ~D[2026-09-03]
      assert event.end_date == ~D[2026-09-04]
    end

    test "falls back to the anchor when the item's zone is one we cannot map" do
      # A Berlin item, so the anchor gets it right; the point is that an
      # unrecognised zone name is discarded rather than raising or nilling the
      # date out.
      item =
        all_day_item("2026-09-02T22:00:00Z", "2026-09-03T22:00:00Z",
          zone: "Neverland Standard Time"
        )

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.start_date == ~D[2026-09-03]
      assert event.end_date == ~D[2026-09-04]
    end

    test "marks a cancelled item cancelled so it stops blocking the diary" do
      item =
        String.replace(
          @timed_item,
          "<t:IsAllDayEvent>false</t:IsAllDayEvent>",
          "<t:IsAllDayEvent>false</t:IsAllDayEvent>\n<t:IsCancelled>true</t:IsCancelled>"
        )

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.status == :cancelled
      refute CalendarEvent.blocking?(event)
    end

    test "leaves an item the server says is not cancelled blocking" do
      item =
        String.replace(
          @timed_item,
          "<t:IsAllDayEvent>false</t:IsAllDayEvent>",
          "<t:IsAllDayEvent>false</t:IsAllDayEvent>\n<t:IsCancelled>false</t:IsCancelled>"
        )

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.status == :confirmed
      assert CalendarEvent.blocking?(event)
    end

    test "maps a Free busy status to transparent so it does not block availability" do
      item = String.replace(@timed_item, "LegacyFreeBusyStatus>Busy", "LegacyFreeBusyStatus>Free")

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.transparency == :transparent
      refute CalendarEvent.blocking?(event)
    end

    test "keeps every other busy status blocking" do
      statuses = ["Busy", "Tentative", "OOF", "WorkingElsewhere", "NoData"]

      events =
        Enum.map(statuses, fn status ->
          item =
            String.replace(
              @timed_item,
              "LegacyFreeBusyStatus>Busy",
              "LegacyFreeBusyStatus>#{status}"
            )

          {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)
          {status, event}
        end)

      assert Enum.reject(events, fn {_status, event} -> CalendarEvent.blocking?(event) end) == []
    end

    test "falls back to the item id when the server omits UID" do
      item = String.replace(@timed_item, ~r|<t:UID>.*</t:UID>|, "")

      assert {:ok, [event]} = EventNormaliser.normalise_events(items([item]), @context)

      assert event.uid == "item-1"
    end

    test "resolves the EWS elements by namespace rather than by prefix" do
      # The prefixes are ones no xpath in this codebase spells, so every value
      # below can only have been extracted by namespace URI. An unbound prefix
      # yields `""` rather than an error, which is how a namespace regression
      # reaches production looking like an empty calendar.
      # The all-day item is the second one because the flags that decide it
      # (`IsAllDayEvent`, `IsCancelled`, `StartTimeZone`) all read back as `""`
      # under an unbound prefix, and `""` is indistinguishable from the
      # server's default answer on each. Only an item whose *correct* value is
      # the non-default one can catch a regression there, so this one is
      # all-day, cancelled, and dated from a zone the anchor gets wrong.
      [timed, all_day] =
        renamed_prefix_items("""
        <types:CalendarItem>
          <types:ItemId Id="item-9" ChangeKey="ck-9"/>
          <types:Subject>Renamed</types:Subject>
          <types:UID>uid-9</types:UID>
          <types:Start>2026-09-01T10:00:00Z</types:Start>
          <types:End>2026-09-01T11:00:00Z</types:End>
          <types:IsAllDayEvent>false</types:IsAllDayEvent>
          <types:LegacyFreeBusyStatus>Free</types:LegacyFreeBusyStatus>
          <types:Location>Room 9</types:Location>
          <types:CalendarItemType>Single</types:CalendarItemType>
        </types:CalendarItem>
        <types:CalendarItem>
          <types:ItemId Id="item-10" ChangeKey="ck-10"/>
          <types:UID>uid-10</types:UID>
          <types:Start>2026-09-02T10:00:00Z</types:Start>
          <types:End>2026-09-03T10:00:00Z</types:End>
          <types:IsAllDayEvent>true</types:IsAllDayEvent>
          <types:IsCancelled>true</types:IsCancelled>
          <types:StartTimeZone Id="Line Islands Standard Time"/>
        </types:CalendarItem>
        """)

      assert {:ok, [event, all_day_event]} =
               EventNormaliser.normalise_events([timed, all_day], @context)

      assert event.uid == "uid-9"
      assert event.provider_event_id == "item-9"
      assert event.etag == "ck-9"
      assert event.summary == "Renamed"
      assert event.location == "Room 9"
      assert event.start_at == ~U[2026-09-01 10:00:00Z]
      assert event.end_at == ~U[2026-09-01 11:00:00Z]
      assert event.transparency == :transparent
      assert event.provider_metadata == %{"calendar_item_type" => "Single"}

      assert all_day_event.all_day == true
      assert all_day_event.status == :cancelled
      assert all_day_event.start_date == ~D[2026-09-03]
      assert all_day_event.end_date == ~D[2026-09-04]
    end

    test "normalises an empty batch to an empty list" do
      assert {:ok, []} = EventNormaliser.normalise_events([], @context)
    end

    test "an error response message contributes no item, leaving the rest intact" do
      # A `GetItemResponseMessage` with ResponseClass="Error" carries no
      # `<m:Items>`, so the provider's extraction xpath yields nothing for it.
      # This pins that contract, since the normaliser itself never sees
      # response codes.
      extracted =
        extract_items("""
        <m:GetItemResponseMessage ResponseClass="Error">
          <m:ResponseCode>ErrorItemNotFound</m:ResponseCode>
        </m:GetItemResponseMessage>
        <m:GetItemResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          <m:Items>#{@timed_item}</m:Items>
        </m:GetItemResponseMessage>
        """)

      assert length(extracted) == 1
      assert {:ok, [event]} = EventNormaliser.normalise_events(extracted, @context)
      assert event.uid == "040000008200E00074C5B7101A82E008"
    end

    test "skips an item with unusable timing rather than failing the batch" do
      undated = String.replace(@timed_item, ~r|<t:End>.*</t:End>|, "")

      log =
        capture_log(fn ->
          assert {:ok, [event]} =
                   EventNormaliser.normalise_events(items([undated, @timed_item]), @context)

          assert event.uid == "040000008200E00074C5B7101A82E008"
        end)

      assert log =~ "Skipping unusable Exchange calendar item"
    end

    test "raises an operator alert for a skipped item, carrying no mailbox content" do
      # A dropped event is a meeting missing from the diary with nothing on
      # screen to say so, which is what this alert exists to surface. The
      # subject and location are the item owner's data and must not travel
      # into an alert email.
      undated = String.replace(@timed_item, ~r|<t:End>.*</t:End>|, "")

      capture_log(fn ->
        assert {:ok, []} = EventNormaliser.normalise_events(items([undated]), @context)
      end)

      assert_receive {:send_alert, :invalid_calendar_event, payload}

      assert payload.provider == :exchange
      assert payload.event_uid == "040000008200E00074C5B7101A82E008"
      assert payload.calendar_integration_id == 7
      assert payload.reason

      refute payload |> inspect() |> String.contains?("Standup")
      refute payload |> inspect() |> String.contains?("Room 1")
    end

    test "raises no alert for a batch every item of which is usable" do
      assert {:ok, [_event]} = EventNormaliser.normalise_events(items([@timed_item]), @context)

      refute_receive {:send_alert, :invalid_calendar_event, _payload}
    end

    test "skips an item carrying neither a UID nor an item id" do
      item = """
      <t:CalendarItem>
        <t:Subject>Anonymous</t:Subject>
        <t:Start>2026-09-01T10:00:00Z</t:Start>
        <t:End>2026-09-01T11:00:00Z</t:End>
      </t:CalendarItem>
      """

      assert capture_log(fn ->
               assert {:ok, []} = EventNormaliser.normalise_events(items([item]), @context)
             end) =~ "Skipping unusable Exchange calendar item"

      assert_receive {:send_alert, :invalid_calendar_event, _payload}
    end
  end

  # An all-day item whose boundaries are rendered with the given instants, and
  # optionally carrying a `StartTimeZone`. The `"Z"` form means the
  # midnight-UTC pair a mailbox in UTC reports.
  defp all_day_item(start_at, end_at, opts \\ [])

  defp all_day_item("Z", "Z", opts),
    do: all_day_item("2026-09-03T00:00:00Z", "2026-09-04T00:00:00Z", opts)

  defp all_day_item(start_at, end_at, opts) do
    """
    <t:CalendarItem>
      <t:ItemId Id="item-2" ChangeKey="ck-2"/>
      <t:Subject>Conference</t:Subject>
      <t:UID>uid-2</t:UID>
      <t:Start>#{start_at}</t:Start>
      <t:End>#{end_at}</t:End>
      <t:IsAllDayEvent>true</t:IsAllDayEvent>
      <t:LegacyFreeBusyStatus>Busy</t:LegacyFreeBusyStatus>
      #{start_time_zone(Keyword.get(opts, :zone))}
    </t:CalendarItem>
    """
  end

  defp start_time_zone(nil), do: ""
  defp start_time_zone(id), do: ~s(<t:StartTimeZone Id="#{id}"/>)

  # Returns the `CalendarItem` elements a `GetItem` response would yield, which
  # is the shape the `Provider` behaviour hands to `normalise_events/2`.
  defp items(item_xml) do
    item_xml
    |> Enum.map_join("\n", fn item ->
      """
      <m:GetItemResponseMessage ResponseClass="Success">
        <m:ResponseCode>NoError</m:ResponseCode>
        <m:Items>#{item}</m:Items>
      </m:GetItemResponseMessage>
      """
    end)
    |> extract_items()
  end

  defp extract_items(messages) do
    {:ok, doc} =
      Soap.parse("""
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body>
          <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
                             xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
            <m:ResponseMessages>#{messages}</m:ResponseMessages>
          </m:GetItemResponse>
        </SOAP:Body>
      </SOAP:Envelope>
      """)

    Soap.xpath(doc, ~x"//m:GetItemResponseMessage/m:Items/t:CalendarItem"l)
  end

  defp renamed_prefix_items(item) do
    {:ok, doc} =
      Soap.parse("""
      <?xml version="1.0"?>
      <env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
        <env:Body>
          <msgs:GetItemResponse
              xmlns:msgs="http://schemas.microsoft.com/exchange/services/2006/messages"
              xmlns:types="http://schemas.microsoft.com/exchange/services/2006/types">
            <msgs:ResponseMessages>
              <msgs:GetItemResponseMessage ResponseClass="Success">
                <msgs:ResponseCode>NoError</msgs:ResponseCode>
                <msgs:Items>#{item}</msgs:Items>
              </msgs:GetItemResponseMessage>
            </msgs:ResponseMessages>
          </msgs:GetItemResponse>
        </env:Body>
      </env:Envelope>
      """)

    Soap.xpath(doc, ~x"//m:GetItemResponseMessage/m:Items/t:CalendarItem"l)
  end
end
