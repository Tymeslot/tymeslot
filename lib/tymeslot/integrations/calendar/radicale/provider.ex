defmodule Tymeslot.Integrations.Calendar.Radicale.Provider do
  @moduledoc """
  Simplified Radicale provider that leverages the shared CalDAV base module.

  This provider is now just a thin configuration layer over the base CalDAV
  implementation, providing Radicale-specific defaults and messaging.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :radicale

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Radicale"

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.RadicaleConfig

  @impl Tymeslot.Integrations.Calendar.Provider
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

  @impl Tymeslot.Integrations.Calendar.Provider
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

  @impl Tymeslot.Integrations.Calendar.Provider
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
    ProviderCommon.test_caldav_provider_connection(integration,
      metadata: opts[:metadata],
      success_message: "Radicale connection successful",
      unauthorized_message: "Authentication failed. Check your Radicale username and password.",
      not_found_message: "Radicale server not found. Check your server URL and port if needed.",
      error_formatter: &format_error/1
    )
  end

  @doc """
  Discovers available calendars on the Radicale server.
  """
  @spec discover_calendars(map(), keyword()) :: {:ok, [CalendarEntry.t()]} | {:error, String.t()}
  def discover_calendars(client, opts \\ []) do
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    # Ensure provider is set to radicale for proper discovery URL
    client = Map.put(client, :provider, :radicale)

    CaldavCommon.discover_calendars(client, ip_address: ip_address)
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration),
    do: ProviderCommon.caldav_discover_from_integration(__MODULE__, integration)

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate build_client_configs(integration),
    to: ProviderCommon,
    as: :caldav_build_client_configs

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate build_booking_client_config(integration),
    to: ProviderCommon,
    as: :caldav_build_booking_client_config

  @impl Tymeslot.Integrations.Calendar.Provider
  def create_event(client, event_data), do: CaldavCommon.create_event(client, event_data)

  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(client, uid, event_data),
    do: CaldavCommon.update_event(client, uid, event_data)

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(client, uid, opts \\ []), do: CaldavCommon.delete_event(client, uid, opts)

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(client, opts), do: CaldavCommon.list_events(client, opts)

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(raw_events, context),
    do: EventProcessor.normalise_events(raw_events, context)

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(client), do: CaldavCommon.check_connectivity(client)

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

      _other ->
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
