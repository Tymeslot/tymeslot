defmodule Tymeslot.Integrations.Calendar.Exchange.ProviderTest do
  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations

  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Exchange.EventNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Security.Encryption

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

  describe "write callbacks" do
    test "refuse every write while the provider is read-only" do
      assert {:error, :read_only} = Provider.create_event(config(), %{})
      assert {:error, :read_only} = Provider.update_event(config(), "uid", %{})
      assert {:error, :read_only} = Provider.delete_event(config(), "uid", [])
    end

    test "resolve no booking client, so an Exchange calendar can never be a booking target" do
      assert Provider.build_booking_client_config(integration()) == nil
    end
  end

  describe "list_events/2" do
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

      assert {:ok, [item]} = Provider.list_events(config(), range(calendar_id: "cal-1"))
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

      assert {:ok, [_item]} = Provider.list_events(config(), range())
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

      assert {:ok, []} = Provider.list_events(config(), range())

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

      assert {:ok, []} = Provider.list_events(config(), range())
    end

    test "fails the read when FindItem states a failure, rather than emptying the diary" do
      # A failed response message carries no items, so anything not reading the
      # response code answers `{:ok, []}` — which the sync layer persists as a
      # calendar with nothing in it.
      respond_with(200, ExchangeFixtures.failed_find_item_response("ErrorAccessDenied"))

      assert {:error, {:response_code, "ErrorAccessDenied"}} =
               Provider.list_events(config(), range())
    end

    test "surfaces a transport failure rather than an empty calendar" do
      respond_with(401, "")

      assert {:error, :unauthorized} = Provider.list_events(config(), range())
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

      assert {:ok, items} = Provider.list_events(config(), range())
      assert {:ok, intervals} = Provider.list_busy_intervals(config(), range())

      # The item path is short by three days; the interval path is not. Merging
      # the two lists, or serving availability from the items, loses exactly
      # the three occurrences an organiser would then be double-booked over.
      assert length(items) == 1

      assert Enum.map(intervals, & &1.start_at) == [
               ~U[2026-09-01 10:00:00Z],
               ~U[2026-09-02 10:00:00Z],
               ~U[2026-09-03 10:00:00Z],
               ~U[2026-09-04 10:00:00Z]
             ]

      # Neither list carries the other's shape: items are XML elements, and
      # intervals are maps that no `CalendarItem` xpath can be run over.
      assert Enum.all?(items, &is_tuple/1)
      assert Enum.all?(intervals, &is_map/1)
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

  describe "build_client_configs/1" do
    test "builds one client per selected calendar" do
      integration =
        integration(%{
          calendar_list: [
            %CalendarEntry{id: "cal-1", name: "Calendar", selected: true},
            %CalendarEntry{id: "cal-2", name: "Team", selected: false},
            %CalendarEntry{id: "cal-3", name: "Rooms", selected: true}
          ]
        })

      assert [first, second] = Provider.build_client_configs(integration)
      assert first.calendar_id == "cal-1"
      assert second.calendar_id == "cal-3"
    end

    test "falls back to the mailbox's default calendar when nothing is selected" do
      assert [client] = Provider.build_client_configs(integration())
      assert client.calendar_id == :calendar
    end

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

    test "carries the credentials the transport authenticates with" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert ["Basic " <> encoded] = Conn.get_req_header(conn, "authorization")
        assert Base.decode64!(encoded) == "user@example.com:secret"
        respond(conn, ExchangeFixtures.empty_find_item_response())
      end)

      assert [client] = Provider.build_client_configs(integration())
      assert {:ok, []} = Provider.list_events(client, range())
    end
  end

  defp range(overrides \\ []) do
    Keyword.merge(
      [start_time: ~U[2026-09-01 00:00:00Z], end_time: ~U[2026-10-01 00:00:00Z]],
      overrides
    )
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
