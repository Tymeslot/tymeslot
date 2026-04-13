defmodule Tymeslot.Integrations.Calendar.FacadeTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  setup :verify_on_exit!

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
      assert :ok = Calendar.check_provider_connectivity(integration)
    end

    test "returns :ok for Outlook provider" do
      integration = integration_for(:outlook)
      assert :ok = Calendar.check_provider_connectivity(integration)
    end

    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)
      assert {:error, _reason} = Calendar.check_provider_connectivity(integration)
    end
  end

  describe "create_provider_event/2" do
    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)
      assert {:error, _reason} = Calendar.create_provider_event(integration, %{})
    end
  end

  describe "update_provider_event/3" do
    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)

      assert {:error, _reason} =
               Calendar.update_provider_event(integration, "event-123", %{})
    end
  end

  describe "delete_provider_event/2" do
    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)
      assert {:error, _reason} = Calendar.delete_provider_event(integration, "event-123")
    end
  end

  describe "fetch_and_normalise_provider_events/3" do
    test "returns {:error, reason} when provider is unknown" do
      integration = integration_for(:unknown)
      range_start = DateTime.utc_now()
      range_end = DateTime.add(range_start, 7, :day)

      assert {:error, _reason} =
               Calendar.fetch_and_normalise_provider_events(integration, range_start, range_end)
    end
  end

  describe "check_provider_connectivity/1 (CalDAV happy path)" do
    # End-to-end routing test: facade → ProviderAdapter → Provider module →
    # CaldavCommon.check_connectivity → Http.propfind → http_client. Proves the
    # whole CalDAV chain wires up and that Http.propfind is reachable from
    # facade callers, which was the main gap after refactoring CaldavCommon to
    # stop using Req.request directly.
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

      assert :ok = Calendar.check_provider_connectivity(integration)
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

      assert {:error, :unauthorized} = Calendar.check_provider_connectivity(integration)
    end
  end
end
