defmodule Tymeslot.Integrations.Calendar.ProviderAdapterTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter

  defmodule ErroringProvider do
    @spec get_events(any()) :: {:error, :boom}
    def get_events(_client), do: {:error, :boom}

    @spec get_events(any(), DateTime.t(), DateTime.t()) :: {:error, :boom}
    def get_events(_client, _start, _end), do: {:error, :boom}

    @spec create_event(any(), map()) :: {:error, :boom}
    def create_event(_client, _event), do: {:error, :boom}

    @spec update_event(any(), String.t(), map()) :: {:error, :boom}
    def update_event(_client, _uid, _event), do: {:error, :boom}

    @spec delete_event(any(), String.t()) :: {:error, :boom}
    def delete_event(_client, _uid), do: {:error, :boom}
  end

  defmodule ThreeTupleErrorProvider do
    def get_events(_client), do: {:error, :unauthorized, "Token expired"}
    def get_events(_client, _start, _end), do: {:error, :rate_limited, "Too many requests"}
    def create_event(_client, _event), do: {:error, :unauthorized, "Insufficient permissions"}
    def update_event(_client, _uid, _event), do: {:error, :not_found, "Event not found"}
    def delete_event(_client, _uid), do: {:error, :network_error, "Connection refused"}
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
    assert {:error, :unauthorized, "Token expired"} = ProviderAdapter.get_events(client)

    assert {:error, :rate_limited, "Too many requests"} =
             ProviderAdapter.get_events(client, DateTime.utc_now(), DateTime.utc_now())

    assert {:error, :unauthorized, "Insufficient permissions"} =
             ProviderAdapter.create_event(client, %{})

    assert {:error, :not_found, "Event not found"} =
             ProviderAdapter.update_event(client, "uid", %{})

    assert {:error, :network_error, "Connection refused"} =
             ProviderAdapter.delete_event(client, "uid")
  end
end
