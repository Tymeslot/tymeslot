defmodule Tymeslot.Integrations.Calendar.Radicale.Provider do
  @moduledoc """
  Simplified Radicale provider that leverages the shared CalDAV base module.

  This provider is now just a thin configuration layer over the base CalDAV
  implementation, providing Radicale-specific defaults and messaging.
  """

  @behaviour Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour

  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}

  @impl true
  def provider_type, do: :radicale

  @impl true
  def display_name, do: "Radicale"

  @impl true
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        description: "Radicale server URL (e.g., https://radicale.example.com:5232)"
      },
      username: %{
        type: :string,
        required: true,
        description: "Radicale username"
      },
      password: %{
        type: :string,
        required: true,
        description: "Radicale password"
      },
      calendar_paths: %{
        type: :list,
        required: false,
        description: "List of calendar UUIDs to sync (auto-discovered if not provided)"
      },
      connection_timeout: %{
        type: :integer,
        required: false,
        default: 10_000,
        description: "Connection timeout in milliseconds (default: 10 seconds)"
      },
      request_timeout: %{
        type: :integer,
        required: false,
        default: 30_000,
        description: "Request timeout in milliseconds (default: 30 seconds)"
      },
      discovery_timeout: %{
        type: :integer,
        required: false,
        default: 15_000,
        description: "Calendar discovery timeout in milliseconds (default: 15 seconds)"
      }
    }
  end

  @impl true
  def validate_config(config) do
    with :ok <- ProviderCommon.validate_required_fields(config, [:base_url, :username, :password]),
         :ok <-
           ProviderCommon.validate_url(config[:base_url],
             message:
               "Invalid Radicale URL. Should be your Radicale server URL (e.g., https://radicale.example.com:5232)"
           ),
         {:ok, client} <- build_test_client(config) do
      ProviderCommon.test_caldav_connection(client,
        error_formatter: &radicale_error_formatter/1
      )
    end
  end

  @impl true
  def new(config) do
    CaldavCommon.build_client(
      %{
        base_url: normalize_base_url(config[:base_url]),
        username: config[:username],
        password: config[:password],
        calendar_paths: build_radicale_calendar_paths(config),
        verify_ssl: true,
        connection_timeout: config[:connection_timeout] || 10_000,
        request_timeout: config[:request_timeout] || 30_000,
        discovery_timeout: config[:discovery_timeout] || 15_000
      },
      provider: :radicale
    )
  end

  @doc """
  Tests connection to Radicale server with Radicale-specific messaging.
  """
  @spec test_connection(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def test_connection(integration, opts \\ []) do
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    client = %{
      base_url: integration.base_url,
      username: integration.username,
      password: integration.password,
      calendar_paths: integration.calendar_paths || [],
      verify_ssl: true,
      provider: :radicale
    }

    case CaldavCommon.test_connection(client, ip_address: ip_address) do
      {:ok, _} ->
        {:ok, "Radicale connection successful"}

      {:error, :unauthorized} ->
        {:error, "Authentication failed. Check your Radicale username and password."}

      {:error, :not_found} ->
        {:error, "Radicale server not found. Check your server URL and port if needed."}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  @doc """
  Discovers available calendars on the Radicale server.
  """
  @spec discover_calendars(map(), keyword()) :: {:ok, list(map())} | {:error, String.t()}
  def discover_calendars(client, opts \\ []) do
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    # Ensure provider is set to radicale for proper discovery URL
    client = Map.put(client, :provider, :radicale)

    CaldavCommon.discover_calendars(client, ip_address: ip_address)
  end

  @impl true
  def get_events(client), do: CaldavCommon.get_events(client)

  @impl true
  def get_events(client, start_time, end_time),
    do: CaldavCommon.get_events(client, start_time, end_time)

  @impl true
  def create_event(client, event_data), do: CaldavCommon.create_event(client, event_data)

  @impl true
  def update_event(client, uid, event_data),
    do: CaldavCommon.update_event(client, uid, event_data)

  @impl true
  def delete_event(client, uid), do: CaldavCommon.delete_event(client, uid)

  # Private helper functions

  defp build_test_client(config) do
    full_client = new(config)

    client = %{
      base_url: full_client.base_url,
      username: full_client.username,
      password: full_client.password,
      calendar_paths: full_client.calendar_paths,
      verify_ssl: true,
      provider: full_client.provider
    }

    {:ok, client}
  end

  defp normalize_base_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp build_radicale_calendar_paths(config) do
    # If calendar_paths is provided (from operations.ex for fetching), use it directly
    # Otherwise, build from calendar_names (for initial setup/discovery)
    case config[:calendar_paths] do
      paths when is_list(paths) and paths != [] ->
        paths

      _ ->
        build_radicale_default_paths(config)
    end
  end

  defp radicale_error_formatter(reason),
    do: ErrorHandler.sanitize_error_message(reason, :radicale)

  defp build_radicale_default_paths(config) do
    username = config[:username]
    calendar_names = config[:calendar_names] || []

    if Enum.empty?(calendar_names) do
      []
    else
      Enum.map(calendar_names, &format_radicale_path(&1, username))
    end
  end

  defp format_radicale_path(calendar_name, username) do
    if String.starts_with?(calendar_name, "/#{username}/") do
      calendar_name
    else
      "/#{username}/#{calendar_name}/"
    end
  end

  defp format_error({:error, message}) when is_binary(message), do: message
  defp format_error(error), do: "Radicale error: #{inspect(error)}"
end
