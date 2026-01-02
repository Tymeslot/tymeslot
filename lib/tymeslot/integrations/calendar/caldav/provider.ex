defmodule Tymeslot.Integrations.Calendar.CalDAV.Provider do
  @moduledoc """
  Refactored CalDAV calendar provider using the shared base module.

  This is a cleaner implementation that delegates common CalDAV operations
  to the base module and focuses only on provider-specific configuration.
  """

  @behaviour Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour

  alias Tymeslot.Integrations.Calendar.CalDAV.ServerDetector
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon
  alias Tymeslot.Security.RateLimiter

  require Logger

  @impl true
  def provider_type, do: :caldav

  @impl true
  def display_name, do: "CalDAV"

  @impl true
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        description: "CalDAV server URL"
      },
      username: %{
        type: :string,
        required: true,
        description: "Username for authentication"
      },
      password: %{
        type: :string,
        required: true,
        description: "Password for authentication"
      },
      calendar_paths: %{
        type: :list,
        required: false,
        description: "Specific calendar paths (auto-discovered if not provided)"
      }
    }
  end

  @impl true
  def validate_config(config) do
    with :ok <- ProviderCommon.validate_required_fields(config, [:base_url, :username, :password]),
         :ok <- ProviderCommon.validate_url(config[:base_url]),
         client <- new(config) do
      ProviderCommon.test_caldav_connection(client,
        error_formatter: &caldav_error_formatter/1
      )
    end
  end

  @impl true
  def new(config) do
    # Auto-detect server type for hints; provider remains :caldav at API level
    _server_type = ServerDetector.detect_from_url(config[:base_url])

    common_config = %{
      base_url: CaldavCommon.normalize_url(config[:base_url]),
      username: config[:username],
      password: config[:password],
      calendar_paths: config[:calendar_paths] || [],
      verify_ssl: true
    }

    CaldavCommon.build_client(common_config, provider: :caldav)
  end

  @doc """
  Tests connection to the CalDAV server.
  """
  @spec test_connection(map(), keyword()) :: {:ok, String.t()} | {:error, atom() | String.t()}
  def test_connection(integration, opts \\ []) do
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    with :ok <- check_rate_limit(ip_address) do
      client = build_client(integration)
      CaldavCommon.test_connection(client, ip_address: ip_address)
    end
  end

  @doc """
  Discovers available calendars on the CalDAV server.
  """
  @spec discover_calendars(map(), keyword()) :: {:ok, list(map())} | {:error, String.t()}
  def discover_calendars(client, opts \\ []) do
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    with :ok <- check_discovery_rate_limit(ip_address) do
      CaldavCommon.discover_calendars(client, ip_address: ip_address)
    end
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

  defp caldav_error_formatter(:unauthorized), do: "Invalid username or password"
  defp caldav_error_formatter(:not_found), do: "Server not found at specified URL"
  defp caldav_error_formatter(reason), do: format_error(reason)

  defp format_error({:error, message}) when is_binary(message), do: message
  defp format_error(error), do: "Connection failed: #{inspect(error)}"

  defp check_rate_limit(ip_address) do
    case RateLimiter.check_caldav_connection_rate_limit(ip_address) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, message}
    end
  end

  defp check_discovery_rate_limit(ip_address) do
    case RateLimiter.check_calendar_discovery_rate_limit(ip_address) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, message}
    end
  end

  defp build_client(integration) do
    CaldavCommon.build_client(
      %{
        base_url: integration.base_url,
        username: integration.username,
        password: integration.password,
        calendar_paths: integration.calendar_paths || [],
        verify_ssl: true
      },
      provider: :caldav
    )
  end
end
