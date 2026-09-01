defmodule Tymeslot.Integrations.Calendar.DiagnosticsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Diagnostics
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @feed_url "https://feeds.example.com/secret-address/basic.ics"
  @range_start ~U[2026-08-01 00:00:00Z]
  @range_end ~U[2026-08-31 23:59:59Z]

  defp integration_for(provider) do
    %CalendarIntegrationSchema{
      id: 0,
      provider: to_string(provider),
      base_url: nil,
      calendar_paths: [],
      calendar_list: [],
      default_booking_calendar_id: nil,
      is_active: true
    }
  end

  describe "check_provider_connectivity/1" do
    test "returns :ok for OAuth providers (skipped check)" do
      integration = integration_for(:google)
      assert :ok = Diagnostics.check_provider_connectivity(integration)
    end

    test "returns :ok for Outlook provider" do
      integration = integration_for(:outlook)
      assert :ok = Diagnostics.check_provider_connectivity(integration)
    end

    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)
      assert {:error, _reason} = Diagnostics.check_provider_connectivity(integration)
    end
  end

  describe "create_provider_event/2" do
    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)
      assert {:error, _reason} = Diagnostics.create_provider_event(integration, %{})
    end
  end

  describe "update_provider_event/3" do
    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)

      assert {:error, _reason} =
               Diagnostics.update_provider_event(integration, "event-123", %{})
    end
  end

  describe "delete_provider_event/2" do
    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)
      assert {:error, _reason} = Diagnostics.delete_provider_event(integration, "event-123")
    end
  end

  describe "fetch_and_normalise_provider_events/3" do
    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)
      range_start = DateTime.utc_now()
      range_end = DateTime.add(range_start, 7, :day)

      assert {:error, _reason} =
               Diagnostics.fetch_and_normalise_provider_events(
                 integration,
                 range_start,
                 range_end
               )
    end

    test "a raw provider is still dispatched into list_events" do
      integration =
        insert(:calendar_integration,
          provider: "radicale",
          base_url: "https://radicale.example.com",
          calendar_paths: []
        )

      # The CalDAV read path's own guard, reached without any HTTP: proof the
      # raw branch still pairs list_events with normalise_events rather than
      # short-circuiting the way a cache-backed provider does.
      assert {:error, "No calendars configured"} =
               Diagnostics.fetch_and_normalise_provider_events(
                 integration,
                 @range_start,
                 @range_end
               )
    end
  end

  describe "fetch_and_normalise_provider_events/3 with a cache-backed provider" do
    setup do
      integration =
        insert(:calendar_integration,
          provider: "ics_url",
          base_url: "https://feeds.example.com",
          username_encrypted: nil,
          password_encrypted: nil,
          subscription_url_encrypted: Encryption.encrypt(@feed_url)
        )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "ics_url",
        provider_calendar_id: "subscription",
        uid: "cached-event",
        summary: "Sprint planning",
        start_at: ~U[2026-08-10 09:00:00.000000Z],
        end_at: ~U[2026-08-10 10:00:00.000000Z],
        all_day: false
      )

      %{integration: integration}
    end

    test "refuses instead of feeding cache rows to the provider's parser", %{
      integration: integration
    } do
      assert {:error, {:no_raw_representation, "ics_url"}} =
               Diagnostics.fetch_and_normalise_provider_events(
                 integration,
                 @range_start,
                 @range_end
               )
    end

    test "the fresh-fetch path serves the same integration", %{integration: integration} do
      assert {:ok, events} =
               Diagnostics.fetch_fresh_events(integration, @range_start, @range_end)

      assert Enum.map(events, & &1[:uid]) == ["cached-event"]
    end
  end

  describe "check_provider_connectivity/1 (CalDAV happy path)" do
    # End-to-end routing test: Diagnostics → ProviderAdapter → Provider module →
    # CaldavCommon.check_connectivity → Http.propfind → http_client. Proves the
    # whole CalDAV chain wires up and that Http.propfind is reachable from
    # diagnostic callers, which was the main gap after refactoring CaldavCommon
    # to stop using Req.request directly.
    test "returns :ok when the server answers the PROPFIND probe" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "radicale",
          base_url: "https://radicale.example.com"
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      assert :ok = Diagnostics.check_provider_connectivity(integration)
    end

    test "returns {:error, :unauthorized} when the server rejects credentials" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "radicale",
          base_url: "https://radicale.example.com"
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, :unauthorized} = Diagnostics.check_provider_connectivity(integration)
    end
  end
end
