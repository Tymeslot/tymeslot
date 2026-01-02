defmodule Tymeslot.Integrations.Calendar.ProviderAdapterTest do
  use ExUnit.Case, async: true

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

  setup do
    adapter_client = %{
      provider_type: :fake,
      provider_module: ErroringProvider,
      client: %{calendar_path: "/cal/a"}
    }

    {:ok, adapter_client: adapter_client}
  end

  test "propagates errors from provider without crashing", %{adapter_client: client} do
    assert {:error, :boom} = ProviderAdapter.get_events(client)
    assert {:error, :boom} =
             ProviderAdapter.get_events(client, DateTime.utc_now(), DateTime.utc_now())

    assert {:error, :boom} = ProviderAdapter.create_event(client, %{})
    assert {:error, :boom} = ProviderAdapter.update_event(client, "uid", %{})
    assert {:error, :boom} = ProviderAdapter.delete_event(client, "uid")
  end
end
