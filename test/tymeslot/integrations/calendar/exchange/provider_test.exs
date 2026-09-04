defmodule Tymeslot.Integrations.Calendar.Exchange.ProviderTest do
  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations

  import Mox
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Exchange.EventNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  describe "provider identity" do
    test "declares its type, name and rate-limit bucket" do
      assert Provider.provider_type() == :exchange
      assert Provider.display_name() == "Microsoft Exchange"
      assert Provider.connection_test_bucket() == :caldav
    end
  end

  describe "validate_config/1" do
    test "accepts a complete config" do
      assert :ok = Provider.validate_config(config())
    end

    test "rejects a config missing the password" do
      assert {:error, message} = Provider.validate_config(Map.delete(config(), :password))
      assert message =~ "password"
    end

    test "rejects a plain http URL on a public host" do
      assert {:error, _message} =
               Provider.validate_config(
                 config(base_url: "http://mail.example.com/EWS/Exchange.asmx")
               )
    end

    test "performs no network I/O" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("validate_config/1 must not make requests")
      end)

      assert :ok = Provider.validate_config(config())
    end
  end

  describe "list_calendar_items/2" do
    test "enumerates ids then fetches them in one batch" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        {:ok, body, conn} = Conn.read_body(conn)

        case :counters.get(counter, 1) do
          1 ->
            assert body =~ "<m:FindItem"
            assert body =~ ~s(<t:FolderId Id="cal-1"/>)
            respond(conn, ExchangeFixtures.find_item_response())

          2 ->
            assert body =~ "<m:GetItem"
            assert body =~ ~s(Id="item-1")
            assert body =~ ~s(ChangeKey="ck-1")
            respond(conn, ExchangeFixtures.get_item_response())
        end
      end)

      assert {:ok, [item]} = Provider.list_calendar_items(config(), range(calendar_id: "cal-1"))
      assert item_id(item) == "item-1"

      # The whole point of the batch: however many ids the window holds, the
      # cost is one enumeration plus one fetch.
      assert :counters.get(counter, 1) == 2
    end

    test "fetches every id the window holds in the same batch" do
      counter = :counters.new(1, [])
      ids = [{"item-1", "ck-1"}, {"item-2", "ck-2"}, {"item-3", "ck-3"}]

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        {:ok, body, conn} = Conn.read_body(conn)

        case :counters.get(counter, 1) do
          1 ->
            respond(conn, ExchangeFixtures.find_item_response(ids))

          2 ->
            for {id, change_key} <- ids do
              assert body =~ ~s(<t:ItemId Id="#{id}" ChangeKey="#{change_key}"/>)
            end

            respond(conn, ExchangeFixtures.get_item_response())
        end
      end)

      assert {:ok, [_item]} = Provider.list_calendar_items(config(), range())
      assert :counters.get(counter, 1) == 2
    end

    test "skips the batch fetch entirely when the range holds no events" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        {:ok, body, conn} = Conn.read_body(conn)
        refute body =~ "<m:GetItem"
        respond(conn, ExchangeFixtures.empty_find_item_response())
      end)

      assert {:ok, []} = Provider.list_calendar_items(config(), range())

      # `GetItem` demands at least one `t:ItemId`, so an empty batch is a
      # schema fault rather than an empty answer. The count is the assertion:
      # a second request here means one was sent.
      assert :counters.get(counter, 1) == 1
    end

    test "reads the mailbox's default calendar when no folder is named" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ ~s(<t:DistinguishedFolderId Id="calendar"/>)
        respond(conn, ExchangeFixtures.empty_find_item_response())
      end)

      assert {:ok, []} = Provider.list_calendar_items(config(), range())
    end

    test "fails the read when FindItem states a failure, rather than emptying the diary" do
      # A failed response message carries no items, so anything not reading the
      # response code answers `{:ok, []}` — which the sync layer persists as a
      # calendar with nothing in it.
      respond_with(200, ExchangeFixtures.failed_response("FindItem", "ErrorAccessDenied"))

      assert {:error, {:response_code, "ErrorAccessDenied"}} =
               Provider.list_calendar_items(config(), range())
    end

    test "fails the read when every GetItem message states a failure" do
      # The guard `FindItem` carries has to survive one step further: a batch
      # denied in full carries no `m:Items` either, so walking straight to the
      # calendar items answers `{:ok, []}` for a folder that was read and
      # refused.
      stub_find_item_then_get_item(
        ExchangeFixtures.get_item_batch_response([{:error, "ErrorAccessDenied"}])
      )

      assert {:error, {:response_code, "ErrorAccessDenied"}} =
               Provider.list_calendar_items(config(), range())
    end

    test "returns the readable items when only part of the GetItem batch failed" do
      LogCapture.attach()

      stub_find_item_then_get_item(
        ExchangeFixtures.get_item_batch_response([
          {:ok, [id: "item-1"]},
          {:error, "ErrorItemNotFound"}
        ])
      )

      assert {:ok, [item]} = Provider.list_calendar_items(config(), range())
      assert item_id(item) == "item-1"

      # An item deleted between the enumeration and the fetch is the ordinary
      # cause, so it must not fail the window — but it is still an event
      # missing from the grid, and the log line is the only record of it.
      assert_receive {:captured_log, %{level: :warning, meta: %{failed_item_count: 1} = meta}}
      assert meta.response_codes == "ErrorItemNotFound"
    end

    test "surfaces a transport failure rather than an empty calendar" do
      respond_with(401, "")

      assert {:error, :unauthorized} = Provider.list_calendar_items(config(), range())
    end
  end

  describe "list_busy_intervals/2" do
    test "asks GetUserAvailability for the mailbox and answers its intervals" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "<m:GetUserAvailabilityRequest"
        assert body =~ "<t:Address>room@example.com</t:Address>"

        respond(
          conn,
          ExchangeFixtures.availability_response([
            {"2026-09-01T10:00:00Z", "2026-09-01T11:00:00Z"},
            {"2026-09-02T10:00:00Z", "2026-09-02T11:00:00Z"}
          ])
        )
      end)

      assert {:ok, [first, second]} =
               Provider.list_busy_intervals(
                 config(provider_account_email: "room@example.com"),
                 range()
               )

      assert first.start_at == ~U[2026-09-01 10:00:00Z]
      assert first.end_at == ~U[2026-09-01 11:00:00Z]
      assert first.busy_type == :busy
      assert second.start_at == ~U[2026-09-02 10:00:00Z]
    end

    test "prefers the account's own address over the login it authenticates with" do
      # An on-premises mailbox is routinely logged into as one identity and
      # addressed as another, so the stored address wins wherever there is one.
      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "<t:Address>room@example.com</t:Address>"
        refute body =~ "user@example.com"
        respond(conn, ExchangeFixtures.availability_response())
      end)

      assert {:ok, [_interval]} =
               Provider.list_busy_intervals(
                 config(username: "user@example.com", provider_account_email: "room@example.com"),
                 range()
               )
    end

    test "falls back to the username when that is itself an address" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "<t:Address>user@example.com</t:Address>"
        respond(conn, ExchangeFixtures.availability_response())
      end)

      assert {:ok, [_interval]} = Provider.list_busy_intervals(config(), range())
    end

    test "ignores a stored address that is blank and falls back to the username" do
      # A cleared field arrives as `""`, not as nil: the column is written from
      # a form. Addressing the operation to it asks the server about a mailbox
      # named nothing, and the empty free/busy view that comes back reads as a
      # mailbox with nothing in the diary.
      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "<t:Address>user@example.com</t:Address>"
        respond(conn, ExchangeFixtures.availability_response())
      end)

      assert {:ok, [_interval]} =
               Provider.list_busy_intervals(
                 config(username: "user@example.com", provider_account_email: ""),
                 range()
               )
    end

    test "refuses to read availability when no mailbox address can be resolved" do
      # `DOMAIN\samaccountname` is a valid on-premises login and not a mailbox
      # address. Sending it would fault, but the failure that matters is the
      # one where an unusable address yields no intervals and reads as a free
      # week, so nothing is sent at all.
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("no availability request may be made without a mailbox address")
      end)

      assert {:error, :no_mailbox_address} =
               Provider.list_busy_intervals(
                 config(username: "EXAMPLE\\jdoe", provider_account_email: nil),
                 range()
               )
    end

    test "surfaces a free/busy answer carrying no response code, never an empty diary" do
      respond_with(200, ExchangeFixtures.empty_availability_response())

      assert {:error, :no_response_code} = Provider.list_busy_intervals(config(), range())
    end

    test "surfaces a transport failure rather than an empty diary" do
      respond_with(403, "")

      assert {:error, :forbidden} = Provider.list_busy_intervals(config(), range())
    end
  end

  describe "the two reads" do
    test "a recurring series is complete in the intervals and incomplete in the items" do
      # This is the reason the provider reads twice. `FindItem` over a
      # `CalendarView` answers one `RecurringMaster` dated to the first
      # occurrence, so the item path sees one meeting where the mailbox holds
      # four. `GetUserAvailability` expands the series.
      days = ["01", "02", "03", "04"]

      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        {:ok, body, conn} = Conn.read_body(conn)

        cond do
          body =~ "<m:FindItem" ->
            respond(conn, ExchangeFixtures.find_item_response())

          body =~ "<m:GetItem" ->
            respond(
              conn,
              ExchangeFixtures.get_item_response(calendar_item_type: "RecurringMaster")
            )

          body =~ "<m:GetUserAvailabilityRequest" ->
            respond(
              conn,
              ExchangeFixtures.availability_response(
                Enum.map(days, &{"2026-09-#{&1}T10:00:00Z", "2026-09-#{&1}T11:00:00Z"})
              )
            )
        end
      end)

      assert {:ok, items} = Provider.list_calendar_items(config(), range())
      assert {:ok, intervals} = Provider.list_busy_intervals(config(), range())

      {:ok, events} =
        Provider.normalise_events(items, %{
          calendar_integration_id: 7,
          provider_calendar_id: "cal-1",
          synced_at: ~U[2026-09-01 09:00:00Z]
        })

      # The item path answers the series itself, dated to its first occurrence
      # and saying so: `RecurringMaster` is the only signal in the response
      # that the one item stands for more days than it states.
      assert [%{provider_metadata: %{"calendar_item_type" => "RecurringMaster"}} = event] = events
      assert event.start_at == ~U[2026-09-01 10:00:00Z]

      # The interval path is not short. Merging the two lists, or serving
      # availability from the items, loses exactly the three occurrences an
      # organiser would then be double-booked over.
      assert Enum.map(intervals, & &1.start_at) == [
               ~U[2026-09-01 10:00:00Z],
               ~U[2026-09-02 10:00:00Z],
               ~U[2026-09-03 10:00:00Z],
               ~U[2026-09-04 10:00:00Z]
             ]
    end
  end

  describe "normalise_events/2" do
    test "turns the items of a GetItem response into canonical events" do
      {:ok, doc} = Soap.parse(ExchangeFixtures.get_item_response())
      items = EventNormaliser.parse_items(doc)

      context = %{
        calendar_integration_id: 7,
        provider_calendar_id: "cal-1",
        synced_at: ~U[2026-09-01 09:00:00Z]
      }

      assert {:ok, [event]} = Provider.normalise_events(items, context)
      assert event.uid == "uid-1"
      assert event.summary == "Standup"
      assert event.provider == :exchange
      assert event.start_at == ~U[2026-09-01 10:00:00Z]
    end
  end

  describe "perform_connection_test/1" do
    test "succeeds when the endpoint answers a FindFolder" do
      respond_with(200, ExchangeFixtures.find_folder_response())

      assert {:ok, message} = Provider.perform_connection_test(config())
      assert message =~ "Exchange"
    end

    test "names the credentials when the server rejects them" do
      respond_with(401, "")

      assert {:error, message} = Provider.perform_connection_test(config())
      assert message =~ "credentials"
    end

    test "names the endpoint when it is not there" do
      respond_with(404, "")

      assert {:error, message} = Provider.perform_connection_test(config())
      assert message =~ "EWS"
    end

    test "reports the denial when the server refused the folder read under a 200" do
      # EWS states this failure in the body, not in the status, so a test that
      # stops at the HTTP layer tells the account owner the connection works
      # and leaves discovery and sync to fail afterwards.
      respond_with(200, ExchangeFixtures.failed_response("FindFolder", "ErrorAccessDenied"))

      assert {:error, message} = Provider.perform_connection_test(config())
      assert message =~ "Access denied"
      refute message =~ "successful"
    end
  end

  describe "check_connectivity/1" do
    test "reports the endpoint reachable" do
      respond_with(200, ExchangeFixtures.find_folder_response())

      assert {:ok, %{status: :ok}} = Provider.check_connectivity(config())
    end

    test "surfaces the transport reason unchanged, so the sync layer can classify it" do
      respond_with(503, "")

      assert {:error, :server_error} = Provider.check_connectivity(config())
    end

    test "refuses to call an endpoint reachable when it denied the folder read" do
      respond_with(200, ExchangeFixtures.failed_response("FindFolder", "ErrorAccessDenied"))

      assert {:error, {:response_code, "ErrorAccessDenied"}} =
               Provider.check_connectivity(config())
    end
  end

  describe "discovery" do
    test "lists the mailbox's calendar folders" do
      respond_with(200, ExchangeFixtures.find_folder_response())

      assert {:ok, [%CalendarEntry{} = entry]} = Provider.discover_calendars(config())
      assert entry.id == "cal-1"
      assert entry.name == "Calendar"
    end

    test "discovers against a persisted integration's stored credentials" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert ["Basic " <> encoded] = Conn.get_req_header(conn, "authorization")
        assert Base.decode64!(encoded) == "user@example.com:secret"
        respond(conn, ExchangeFixtures.find_folder_response())
      end)

      assert {:ok, [%CalendarEntry{id: "cal-1"}]} =
               Provider.discover_calendars_for_integration(integration())
    end
  end

  describe "item_client_configs/1" do
    test "builds one client per selected calendar" do
      integration =
        integration(%{
          calendar_list: [
            %CalendarEntry{id: "cal-1", name: "Calendar", selected: true},
            %CalendarEntry{id: "cal-2", name: "Team", selected: false},
            %CalendarEntry{id: "cal-3", name: "Rooms", selected: true}
          ]
        })

      assert [first, second] = Provider.item_client_configs(integration)
      assert first.calendar_id == "cal-1"
      assert second.calendar_id == "cal-3"
    end

    test "drops a selected calendar the discovery named no folder id for" do
      # A client carrying no folder id does not read nothing: `list_events/2`
      # falls back to the mailbox's default calendar, so the window is synced
      # twice under two different calendar ids and every meeting in it is
      # duplicated in the grid. An empty id fares worse and faults the request.
      integration =
        integration(%{
          calendar_list: [
            %CalendarEntry{id: nil, name: "Unidentified", selected: true},
            %CalendarEntry{id: "", name: "Also unidentified", selected: true},
            %CalendarEntry{id: "cal-2", name: "Team", selected: true}
          ]
        })

      assert [client] = Provider.item_client_configs(integration)
      assert client.calendar_id == "cal-2"
    end

    test "falls back to the mailbox's default calendar when nothing is selected" do
      assert [client] = Provider.item_client_configs(integration())
      assert client.calendar_id == :calendar
    end

    test "carries the credentials the transport authenticates with" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert ["Basic " <> encoded] = Conn.get_req_header(conn, "authorization")
        assert Base.decode64!(encoded) == "user@example.com:secret"
        respond(conn, ExchangeFixtures.empty_find_item_response())
      end)

      assert [client] = Provider.item_client_configs(integration())
      assert {:ok, []} = Provider.list_calendar_items(client, range())
    end
  end

  describe "build_client_configs/1" do
    test "carries the account's own mailbox address through to the availability read" do
      integration = integration(%{provider_account_email: "shared@example.com"})

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        assert body =~ "<t:Address>shared@example.com</t:Address>"
        respond(conn, ExchangeFixtures.availability_response())
      end)

      assert [client] = Provider.build_client_configs(integration)
      assert {:ok, [_interval]} = Provider.list_busy_intervals(client, range())
    end

    test "builds one whole-mailbox client, whatever the folder selection" do
      # The availability read is a cache read keyed by integration, so a
      # client per folder would run the same query once per folder. It is also
      # the honest shape: `GetUserAvailability` answers for a mailbox, not a
      # folder.
      integration =
        integration(%{
          calendar_list: [
            %CalendarEntry{id: "cal-1", name: "Calendar", selected: true},
            %CalendarEntry{id: "cal-3", name: "Rooms", selected: true}
          ]
        })

      assert [client] = Provider.build_client_configs(integration)
      refute Map.has_key?(client, :calendar_id)
    end

    test "carries the integration the availability read caches under" do
      # Without this the cache read has nothing to look the rows up by, and
      # `list_events/2` refuses rather than reporting a free diary.
      assert [client] = Provider.build_client_configs(integration(%{id: 4242}))
      assert client.calendar_integration_id == 4242
    end
  end

  describe "config from a persisted integration" do
    test "carries the integration's opt-out of certificate verification to the transport" do
      # `to_provider_config/1` is shaped for the CalDAV family and drops
      # `verify_ssl`, so the merge in `to_config/1` is the only thing keeping
      # it. Without it every on-premises server with a self-signed certificate
      # fails its TLS handshake however the account owner set the option.
      #
      # Asserted at the HTTP-client boundary because Req.Test replaces the
      # adapter, so no connect option ever reaches the stub plug.
      with_config(:tymeslot, :http_client_module, HTTPClientMock)

      expect(HTTPClientMock, :post, fn _url, _body, _headers, opts ->
        assert opts[:connect_options] == [transport_opts: [verify: :verify_none]]

        {:ok, %Req.Response{status: 200, body: ExchangeFixtures.find_folder_response()}}
      end)

      assert {:ok, [%CalendarEntry{id: "cal-1"}]} =
               Provider.discover_calendars_for_integration(integration(%{verify_ssl: false}))
    end
  end

  defp range(overrides \\ []) do
    Keyword.merge(
      [start_time: ~U[2026-09-01 00:00:00Z], end_time: ~U[2026-10-01 00:00:00Z]],
      overrides
    )
  end

  # `list_events/2` costs two round trips, and the second is the one under
  # test: the first answers a single id so that a batch is sent at all.
  defp stub_find_item_then_get_item(get_item_body) do
    counter = :counters.new(1, [])

    ReqTest.stub(:tymeslot_http, fn conn ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> respond(conn, ExchangeFixtures.find_item_response())
        2 -> respond(conn, get_item_body)
      end
    end)
  end

  defp respond(conn, body) do
    conn
    |> Conn.put_resp_content_type("text/xml")
    |> Conn.resp(200, body)
  end

  # The raw items `list_events/2` returns are opaque XML; this reaches into one
  # to prove the right item came back without asserting on the whole document.
  defp item_id(item), do: Soap.xpath(item, ~x"./t:ItemId/@Id"s)

  defp integration(overrides \\ %{}) do
    Map.merge(
      %CalendarIntegrationSchema{
        id: 1,
        provider: "exchange",
        base_url: "https://mail.example.com/EWS/Exchange.asmx",
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        verify_ssl: true,
        calendar_list: []
      },
      Map.new(overrides)
    )
  end
end
