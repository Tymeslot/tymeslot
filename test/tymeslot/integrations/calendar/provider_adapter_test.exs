defmodule Tymeslot.Integrations.Calendar.ProviderAdapterTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter

  defmodule ErroringProvider do
    @spec list_events(any(), keyword()) :: {:error, :boom}
    def list_events(_client, _opts), do: {:error, :boom}

    @spec create_event(any(), map()) :: {:error, :boom}
    def create_event(_client, _event), do: {:error, :boom}

    @spec update_event(any(), String.t(), map()) :: {:error, :boom}
    def update_event(_client, _uid, _event), do: {:error, :boom}

    @spec delete_event(any(), String.t(), keyword()) :: {:error, :boom}
    def delete_event(_client, _uid, _opts), do: {:error, :boom}
  end

  defmodule ThreeTupleErrorProvider do
    def list_events(_client, _opts), do: {:error, :rate_limited, "Too many requests"}
    def create_event(_client, _event), do: {:error, :unauthorized, "Insufficient permissions"}
    def update_event(_client, _uid, _event), do: {:error, :not_found, "Event not found"}
    def delete_event(_client, _uid, _opts), do: {:error, :network_error, "Connection refused"}
  end

  setup do
    adapter_client = %{
      provider_type: :fake,
      provider_module: ErroringProvider,
      client: %{calendar_path: "/cal/a"}
    }

    three_tuple_client = %{
      provider_type: :fake,
      provider_module: ThreeTupleErrorProvider,
      client: %{calendar_path: "/cal/a"}
    }

    {:ok, adapter_client: adapter_client, three_tuple_client: three_tuple_client}
  end

  test "propagates 2-tuple errors from provider without crashing", %{adapter_client: client} do
    assert {:error, :boom} = ProviderAdapter.get_events(client)

    assert {:error, :boom} =
             ProviderAdapter.get_events(client, DateTime.utc_now(), DateTime.utc_now())

    assert {:error, :boom} = ProviderAdapter.create_event(client, %{})
    assert {:error, :boom} = ProviderAdapter.update_event(client, "uid", %{})
    assert {:error, :boom} = ProviderAdapter.delete_event(client, "uid")
  end

  test "passes 3-tuple errors through unchanged", %{three_tuple_client: client} do
    assert {:error, :rate_limited, "Too many requests"} = ProviderAdapter.get_events(client)

    assert {:error, :rate_limited, "Too many requests"} =
             ProviderAdapter.get_events(client, DateTime.utc_now(), DateTime.utc_now())

    assert {:error, :unauthorized, "Insufficient permissions"} =
             ProviderAdapter.create_event(client, %{})

    assert {:error, :not_found, "Event not found"} =
             ProviderAdapter.update_event(client, "uid", %{})

    assert {:error, :network_error, "Connection refused"} =
             ProviderAdapter.delete_event(client, "uid")
  end

  describe "new_client_from_integration/1" do
    test "OAuth provider: uses the integration struct as the client" do
      integration = %CalendarIntegrationSchema{id: 1, provider: "google"}

      assert {:ok, adapter_client} = ProviderAdapter.new_client_from_integration(integration)
      assert adapter_client.provider_type == :google
      assert adapter_client.client == integration
      assert adapter_client.provider_module == Tymeslot.Integrations.Calendar.Google.Provider
    end

    test "OAuth provider: Outlook wires the correct provider module" do
      integration = %CalendarIntegrationSchema{id: 2, provider: "outlook"}

      assert {:ok, adapter_client} = ProviderAdapter.new_client_from_integration(integration)
      assert adapter_client.provider_type == :outlook
      assert adapter_client.provider_module == Tymeslot.Integrations.Calendar.Outlook.Provider
    end

    test "CalDAV provider: decrypts credentials and builds a client struct" do
      integration = %CalendarIntegrationSchema{
        id: 3,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/calendars/user/inbox/"],
        username_encrypted: nil,
        password_encrypted: nil
      }

      assert {:ok, adapter_client} = ProviderAdapter.new_client_from_integration(integration)
      assert adapter_client.provider_type == :caldav
      assert adapter_client.provider_module == Tymeslot.Integrations.Calendar.CalDAV.Provider
      # CalDAV client is a map built from normalised config, NOT the integration.
      assert adapter_client.client.base_url == "https://caldav.example.com"
      assert adapter_client.client.calendar_paths == ["/calendars/user/inbox/"]
      refute adapter_client.client == integration
    end

    test "returns {:error, _} for an unknown provider" do
      integration = %CalendarIntegrationSchema{id: 4, provider: "unknown"}
      assert {:error, _reason} = ProviderAdapter.new_client_from_integration(integration)
    end
  end
end
