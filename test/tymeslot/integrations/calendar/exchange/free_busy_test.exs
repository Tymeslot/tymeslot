defmodule Tymeslot.Integrations.Calendar.Exchange.FreeBusyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Exchange.FreeBusy
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  describe "parse_intervals/1" do
    test "returns every busy interval the server listed, in order" do
      doc =
        response(
          view(
            event("2026-11-02T09:00:00Z", "2026-11-02T09:15:00Z", "Busy") <>
              event("2026-11-03T09:00:00Z", "2026-11-03T09:15:00Z", "Busy")
          )
        )

      assert {:ok, [first, second]} = FreeBusy.parse_intervals(doc)

      assert first.start_at == ~U[2026-11-02 09:00:00Z]
      assert first.end_at == ~U[2026-11-02 09:15:00Z]
      assert first.busy_type == :busy
      assert second.start_at == ~U[2026-11-03 09:00:00Z]
      assert second.end_at == ~U[2026-11-03 09:15:00Z]
    end

    test "keeps every occurrence of a recurring series, which is why this path exists" do
      # The item path answers one master dated to the first occurrence; this
      # one answers the expansion, and losing any of it books over a meeting.
      days = ["02", "03", "04", "05"]

      doc =
        response(
          view(
            Enum.map_join(
              days,
              &event("2026-11-#{&1}T09:00:00Z", "2026-11-#{&1}T09:15:00Z", "Busy")
            )
          )
        )

      assert {:ok, intervals} = FreeBusy.parse_intervals(doc)

      assert Enum.map(intervals, & &1.start_at) == [
               ~U[2026-11-02 09:00:00Z],
               ~U[2026-11-03 09:00:00Z],
               ~U[2026-11-04 09:00:00Z],
               ~U[2026-11-05 09:00:00Z]
             ]
    end

    test "drops the intervals that do not consume the organiser's time" do
      # `Tentative` is the survivor on purpose: an implementation ignoring
      # `t:BusyType`, or keeping the first element, answers the wrong one.
      doc =
        response(
          view(
            event("2026-11-02T09:00:00Z", "2026-11-02T09:15:00Z", "Free") <>
              event("2026-11-02T10:00:00Z", "2026-11-02T10:30:00Z", "NoData") <>
              event("2026-11-02T11:00:00Z", "2026-11-02T11:30:00Z", "Tentative")
          )
        )

      assert {:ok, [only]} = FreeBusy.parse_intervals(doc)

      assert only.start_at == ~U[2026-11-02 11:00:00Z]
      assert only.busy_type == :tentative
    end

    test "treats an out-of-office interval as busy" do
      doc = response(view(event("2026-11-02T09:00:00Z", "2026-11-02T17:00:00Z", "OOF")))

      assert {:ok, [only]} = FreeBusy.parse_intervals(doc)
      assert only.busy_type == :out_of_office
    end

    test "blocks on a busy type it does not recognise rather than dropping it" do
      # Over-blocking costs a bookable slot; under-blocking double-books.
      doc =
        response(view(event("2026-11-02T09:00:00Z", "2026-11-02T09:15:00Z", "WorkingElsewhere")))

      assert {:ok, [only]} = FreeBusy.parse_intervals(doc)

      assert only.busy_type == :busy
      assert only.start_at == ~U[2026-11-02 09:00:00Z]
    end

    test "blocks on an interval whose busy type the server omitted" do
      doc =
        response(
          view("""
          <t:CalendarEvent>
            <t:StartTime>2026-11-02T09:00:00Z</t:StartTime>
            <t:EndTime>2026-11-02T09:15:00Z</t:EndTime>
          </t:CalendarEvent>
          """)
        )

      assert {:ok, [only]} = FreeBusy.parse_intervals(doc)

      assert only.busy_type == :busy
      assert only.start_at == ~U[2026-11-02 09:00:00Z]
    end

    test "reads an unqualified boundary as UTC, which is the zone the request named" do
      # Real Exchange renders these bounds in the request's time zone without
      # an offset, where grommunio suffixes `Z`. Rejecting the bare form would
      # drop every interval such a server sends.
      doc = response(view(event("2026-11-02T09:00:00", "2026-11-02T09:15:00", "Busy")))

      assert {:ok, [only]} = FreeBusy.parse_intervals(doc)

      assert only.start_at == ~U[2026-11-02 09:00:00Z]
      assert only.end_at == ~U[2026-11-02 09:15:00Z]
    end

    test "shifts a boundary carrying an offset onto UTC" do
      doc =
        response(view(event("2026-11-02T10:00:00+01:00", "2026-11-02T11:30:00+01:00", "Busy")))

      assert {:ok, [only]} = FreeBusy.parse_intervals(doc)

      assert only.start_at == ~U[2026-11-02 09:00:00Z]
      assert only.end_at == ~U[2026-11-02 10:30:00Z]
    end

    test "drops sub-second precision from the boundaries" do
      doc =
        response(view(event("2026-11-02T09:00:00.750Z", "2026-11-02T09:15:00.250Z", "Busy")))

      assert {:ok, [only]} = FreeBusy.parse_intervals(doc)

      assert only.start_at == ~U[2026-11-02 09:00:00Z]
      assert only.end_at == ~U[2026-11-02 09:15:00Z]
    end

    test "a genuinely empty calendar is an empty list, not an error" do
      assert FreeBusy.parse_intervals(response(view(""))) == {:ok, []}
    end

    test "a response carrying no response code is an error, never an empty calendar" do
      # This is what a missing or malformed `t:TimeZone` block produces: an
      # empty body, no fault, no response code. Reading it as `{:ok, []}`
      # reports a fully booked week as free, which is the worst answer this
      # provider can give.
      assert FreeBusy.parse_intervals(response("")) == {:error, :no_response_code}
    end

    test "a response message stating no response code is an error too" do
      doc =
        response("""
        <m:FreeBusyResponseArray><m:FreeBusyResponse>
          <m:ResponseMessage ResponseClass="Success"/>
          <m:FreeBusyView>
            <t:CalendarEventArray>
              #{event("2026-11-02T09:00:00Z", "2026-11-02T09:15:00Z", "Busy")}
            </t:CalendarEventArray>
          </m:FreeBusyView>
        </m:FreeBusyResponse></m:FreeBusyResponseArray>
        """)

      assert FreeBusy.parse_intervals(doc) == {:error, :no_response_code}
    end

    test "surfaces a failed response message rather than reporting no busy time" do
      doc =
        response("""
        <m:FreeBusyResponseArray><m:FreeBusyResponse>
          <m:ResponseMessage ResponseClass="Error">
            <m:MessageText>Proxy request not allowed.</m:MessageText>
            <m:ResponseCode>ErrorProxyRequestNotAllowed</m:ResponseCode>
          </m:ResponseMessage>
        </m:FreeBusyResponse></m:FreeBusyResponseArray>
        """)

      assert FreeBusy.parse_intervals(doc) ==
               {:error, {:response_code, "ErrorProxyRequestNotAllowed"}}
    end

    test "skips an interval whose start cannot be read rather than failing the batch" do
      doc =
        response(
          view(
            event("not-a-time", "2026-11-02T09:15:00Z", "Busy") <>
              event("2026-11-03T09:00:00Z", "2026-11-03T09:15:00Z", "Busy")
          )
        )

      capture_log(fn ->
        assert {:ok, [only]} = FreeBusy.parse_intervals(doc)
        assert only.start_at == ~U[2026-11-03 09:00:00Z]
      end)
    end

    test "skips an interval whose end the server omitted" do
      doc =
        response(
          view("""
          <t:CalendarEvent>
            <t:StartTime>2026-11-02T09:00:00Z</t:StartTime>
            <t:BusyType>Busy</t:BusyType>
          </t:CalendarEvent>
          """)
        )

      capture_log(fn -> assert FreeBusy.parse_intervals(doc) == {:ok, []} end)
    end

    test "says so in the log when it skips an interval, naming no boundary" do
      # A skipped interval is busy time that vanishes from the diary, so it
      # has to leave a trace. The boundaries are the mailbox owner's data and
      # must not be in it.
      doc =
        response(
          view(
            event("2026-11-02T13:37:00Z", "not-a-time", "Busy") <>
              event("2026-11-03T09:00:00Z", "2026-11-03T09:15:00Z", "Busy")
          )
        )

      log = capture_log(fn -> assert {:ok, [_only]} = FreeBusy.parse_intervals(doc) end)

      assert log =~ "Skipping Exchange busy intervals carrying no readable boundary"
      refute log =~ "13:37"
    end

    test "logs nothing when every interval is readable" do
      doc =
        response(
          view(
            event("2026-11-02T09:00:00Z", "2026-11-02T09:15:00Z", "Busy") <>
              event("2026-11-02T10:00:00Z", "2026-11-02T10:30:00Z", "Free")
          )
        )

      log = capture_log(fn -> assert {:ok, [_only]} = FreeBusy.parse_intervals(doc) end)

      refute log =~ "Skipping Exchange busy intervals"
    end

    test "resolves the EWS elements by namespace rather than by prefix" do
      # The prefixes here are ones no xpath in this codebase spells, so every
      # value below can only have been resolved by namespace URI. An unbound
      # prefix yields `""` rather than an error, which is how a namespace
      # regression reaches production looking like a free calendar.
      {:ok, doc} =
        Soap.parse("""
        <?xml version="1.0"?>
        <env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
          <env:Body>
            <msgs:GetUserAvailabilityResponse
                xmlns:msgs="http://schemas.microsoft.com/exchange/services/2006/messages"
                xmlns:types="http://schemas.microsoft.com/exchange/services/2006/types">
              <msgs:FreeBusyResponseArray><msgs:FreeBusyResponse>
                <msgs:ResponseMessage ResponseClass="Success">
                  <msgs:ResponseCode>NoError</msgs:ResponseCode>
                </msgs:ResponseMessage>
                <msgs:FreeBusyView>
                  <types:FreeBusyViewType>FreeBusy</types:FreeBusyViewType>
                  <types:CalendarEventArray>
                    <types:CalendarEvent>
                      <types:StartTime>2026-11-02T09:00:00Z</types:StartTime>
                      <types:EndTime>2026-11-02T09:15:00Z</types:EndTime>
                      <types:BusyType>Tentative</types:BusyType>
                    </types:CalendarEvent>
                  </types:CalendarEventArray>
                </msgs:FreeBusyView>
              </msgs:FreeBusyResponse></msgs:FreeBusyResponseArray>
            </msgs:GetUserAvailabilityResponse>
          </env:Body>
        </env:Envelope>
        """)

      assert {:ok, [only]} = FreeBusy.parse_intervals(doc)

      # `Tentative` rather than `Busy`: a reader that resolved nothing at all
      # would default the busy type to `:busy` and pass an assertion on it.
      assert only.busy_type == :tentative
      assert only.start_at == ~U[2026-11-02 09:00:00Z]
      assert only.end_at == ~U[2026-11-02 09:15:00Z]
    end
  end

  defp event(start_at, end_at, busy_type) do
    """
    <t:CalendarEvent>
      <t:StartTime>#{start_at}</t:StartTime>
      <t:EndTime>#{end_at}</t:EndTime>
      <t:BusyType>#{busy_type}</t:BusyType>
    </t:CalendarEvent>
    """
  end

  defp view(events) do
    """
    <m:FreeBusyResponseArray><m:FreeBusyResponse>
      <m:ResponseMessage ResponseClass="Success">
        <m:ResponseCode>NoError</m:ResponseCode>
      </m:ResponseMessage>
      <m:FreeBusyView>
        <t:FreeBusyViewType>FreeBusy</t:FreeBusyViewType>
        <t:CalendarEventArray>#{events}</t:CalendarEventArray>
      </m:FreeBusyView>
    </m:FreeBusyResponse></m:FreeBusyResponseArray>
    """
  end

  defp response(body) do
    {:ok, doc} =
      Soap.parse("""
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body>
          <m:GetUserAvailabilityResponse
              xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
              xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
            #{body}
          </m:GetUserAvailabilityResponse>
        </SOAP:Body>
      </SOAP:Envelope>
      """)

    doc
  end
end
