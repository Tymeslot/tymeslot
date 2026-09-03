defmodule Tymeslot.Integrations.Calendar.DiagnosticsExchangeTest do
  @moduledoc """
  Covers the Exchange half of the diagnostic surface `mix calendar_audit` runs
  through.

  A sibling of `Tymeslot.Integrations.Calendar.DiagnosticsTest`, which despite
  its name lives in `calendar_test.exs` and covers the CalDAV, OAuth and
  subscription paths. Kept separate rather than merged into it because the two
  need different case templates: that one is a `DataCase` stubbing the HTTP
  client, while these assert on the SOAP actually put on the wire and so need
  `ExchangeCase`'s real transport.

  Every other provider the audit covers is probed by pairing `list_events/2`
  with `normalise_events/2`. Exchange cannot be: its `list_events/2` reads the
  local event cache, which for an ephemeral audit target is empty, so a probe
  built that way would report an empty mailbox as a pass on any server. What is
  asserted here is that the two Exchange reads go to the network instead, and
  that the ephemeral integration carries the two fields the CalDAV-shaped
  provider config has no room for and that the reads refuse to run without.
  """

  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Diagnostics

  @item_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgHAAEAAAM="

  @range {~U[2026-10-01 00:00:00Z], ~U[2026-10-31 00:00:00Z]}

  defp exchange_integration(overrides \\ %{}) do
    Diagnostics.build_ephemeral_exchange_integration(
      Map.merge(
        %{
          url: "https://mail.example.com/EWS/Exchange.asmx",
          username: "EXAMPLE\\alice",
          password: "secret",
          mailbox: "alice@example.com",
          verify_ssl: false
        },
        overrides
      )
    )
  end

  # EWS operations are told apart by the element the envelope carries, which is
  # how one stub can answer a two-call read.
  defp respond_by_operation(responses) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)

      {_operation, response} =
        Enum.find(responses, fn {operation, _response} -> body =~ "<m:#{operation}" end)

      conn
      |> Conn.put_resp_content_type("text/xml")
      |> Conn.resp(200, response)
    end)
  end

  defp find_item_response do
    response_envelope("FindItem", """
    <m:RootFolder>
      <t:Items>
        <t:CalendarItem><t:ItemId Id="#{@item_id}" ChangeKey="ck1"/></t:CalendarItem>
      </t:Items>
    </m:RootFolder>
    """)
  end

  defp get_item_response do
    response_envelope("GetItem", """
    <m:Items>
      <t:CalendarItem>
        <t:ItemId Id="#{@item_id}" ChangeKey="ck1"/>
        <t:Subject>Standup</t:Subject>
        <t:Start>2026-10-06T09:00:00Z</t:Start>
        <t:End>2026-10-06T09:30:00Z</t:End>
        <t:IsAllDayEvent>false</t:IsAllDayEvent>
        <t:LegacyFreeBusyStatus>Busy</t:LegacyFreeBusyStatus>
        <t:UID>040000008200E00074C5B7101A82E00800000000</t:UID>
      </t:CalendarItem>
    </m:Items>
    """)
  end

  defp availability_response(intervals) do
    events =
      Enum.map_join(intervals, "\n", fn {from, to} ->
        """
        <t:CalendarEvent>
          <t:StartTime>#{from}</t:StartTime>
          <t:EndTime>#{to}</t:EndTime>
          <t:BusyType>Busy</t:BusyType>
        </t:CalendarEvent>
        """
      end)

    soap_envelope("""
    <m:GetUserAvailabilityResponse>
      <m:FreeBusyResponseArray>
        <m:FreeBusyResponse>
          <m:ResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode>
          </m:ResponseMessage>
          <m:FreeBusyView>
            <t:FreeBusyViewType>FreeBusy</t:FreeBusyViewType>
            <t:CalendarEventArray>#{events}</t:CalendarEventArray>
          </m:FreeBusyView>
        </m:FreeBusyResponse>
      </m:FreeBusyResponseArray>
    </m:GetUserAvailabilityResponse>
    """)
  end

  describe "build_ephemeral_exchange_integration/1" do
    test "carries the mailbox address the busy read is addressed to" do
      integration = exchange_integration()

      # Not the username: a domain login is not an address, and
      # `GetUserAvailability` refuses outright without one.
      assert %CalendarIntegrationSchema{} = integration
      assert integration.provider == "exchange"
      assert integration.provider_account_email == "alice@example.com"
      assert integration.username == "EXAMPLE\\alice"
    end

    test "carries verify_ssl through to the transport" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, :called)

        conn
        |> Conn.put_resp_content_type("text/xml")
        |> Conn.resp(200, ok_envelope())
      end)

      # An on-premises server behind a self-signed certificate is refused
      # outright if the setting does not survive the struct.
      assert exchange_integration().verify_ssl == false
      assert :ok = Diagnostics.check_provider_connectivity(exchange_integration())
      assert_received :called
    end

    test "defaults to verifying the certificate when the caller says nothing" do
      integration =
        Diagnostics.build_ephemeral_exchange_integration(%{
          url: "https://mail.example.com/EWS/Exchange.asmx",
          username: "alice@example.com",
          password: "secret",
          mailbox: "alice@example.com"
        })

      assert integration.verify_ssl
    end

    test "names no booking target, because the provider refuses writes" do
      assert exchange_integration().default_booking_calendar_id == nil
    end
  end

  describe "fetch_and_normalise_provider_events/3 for Exchange" do
    test "reads the server rather than the event cache" do
      respond_by_operation(%{
        "FindItem" => find_item_response(),
        "GetItem" => get_item_response()
      })

      assert {:ok, [event]} =
               Diagnostics.fetch_and_normalise_provider_events(
                 exchange_integration(),
                 elem(@range, 0),
                 elem(@range, 1)
               )

      # The whole point of the clause: an ephemeral integration has no cached
      # rows at all, so a cache read would answer `{:ok, []}` and every audit
      # scenario would fail to locate the fixture it had just planted.
      assert event.summary == "Standup"
      assert event.provider_event_id == @item_id
      assert event.start_at == ~U[2026-10-06 09:00:00Z]
    end

    test "fails the read rather than shrinking it when a folder cannot be read" do
      respond_with(
        200,
        soap_envelope("""
        <m:FindItemResponse>
          <m:ResponseMessages>
            <m:FindItemResponseMessage ResponseClass="Error">
              <m:ResponseCode>ErrorAccessDenied</m:ResponseCode>
            </m:FindItemResponseMessage>
          </m:ResponseMessages>
        </m:FindItemResponse>
        """)
      )

      # A short event list is indistinguishable from a quiet calendar, so an
      # audit that swallowed this would report passes it had not earned.
      assert {:error, {:response_code, "ErrorAccessDenied"}} =
               Diagnostics.fetch_and_normalise_provider_events(
                 exchange_integration(),
                 elem(@range, 0),
                 elem(@range, 1)
               )
    end
  end

  describe "fetch_exchange_busy_intervals/3" do
    test "returns every occurrence the server expands a series into" do
      respond_by_operation(%{
        "GetUserAvailabilityRequest" =>
          availability_response([
            {"2026-10-06T09:00:00Z", "2026-10-06T09:30:00Z"},
            {"2026-10-07T09:00:00Z", "2026-10-07T09:30:00Z"},
            {"2026-10-08T09:00:00Z", "2026-10-08T09:30:00Z"}
          ])
      })

      assert {:ok, intervals} =
               Diagnostics.fetch_exchange_busy_intervals(
                 exchange_integration(),
                 elem(@range, 0),
                 elem(@range, 1)
               )

      # The item read above answers one `RecurringMaster` for the same series.
      # These three are what availability is actually served from, and the only
      # reason the audit performs a second read at all.
      assert Enum.map(intervals, & &1.start_at) == [
               ~U[2026-10-06 09:00:00Z],
               ~U[2026-10-07 09:00:00Z],
               ~U[2026-10-08 09:00:00Z]
             ]
    end

    test "refuses a mailbox it has no address for" do
      integration = %{exchange_integration() | provider_account_email: nil, username: "alice"}

      # Reporting `{:ok, []}` here would say the mailbox is free for the whole
      # window under a success, which is the worst answer this provider can give.
      assert {:error, :no_mailbox_address} =
               Diagnostics.fetch_exchange_busy_intervals(
                 integration,
                 elem(@range, 0),
                 elem(@range, 1)
               )
    end
  end
end
