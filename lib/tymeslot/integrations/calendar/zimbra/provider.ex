defmodule Tymeslot.Integrations.Calendar.Zimbra.Provider do
  @moduledoc """
  Zimbra provider that leverages the shared CalDAV base module.

  Zimbra uses CalDAV for calendar access with the standard path pattern:
  /dav/{username}/ for calendar discovery.

  This provider is a thin configuration layer over the base CalDAV
  implementation, providing Zimbra-specific defaults and messaging.
  """

  @behaviour Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour

  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def provider_type, do: :zimbra

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def display_name, do: "Zimbra"

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.ZimbraConfig

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        description:
          "Zimbra server URL (e.g., https://mail.example.com) or full CalDAV URL (e.g., https://mail.example.com/dav/user@example.com)"
      },
      username: %{
        type: :string,
        required: true,
        description: "Zimbra username (usually your email address)"
      },
      password: %{
        type: :string,
        required: true,
        description: "Zimbra password"
      },
      calendar_paths: %{
        type: :list,
        required: false,
        description: "List of calendar paths to sync (auto-discovered if not provided)"
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

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def validate_config(config) do
    with :ok <- ProviderCommon.validate_required_fields(config, [:base_url, :username, :password]),
         :ok <-
           ProviderCommon.validate_url(config[:base_url],
             message:
               "Invalid Zimbra URL. Should be your Zimbra server URL (e.g., https://mail.example.com) or full CalDAV URL (e.g., https://mail.example.com/dav/user@example.com)"
           ),
         {:ok, client} <- build_test_client(config) do
      ProviderCommon.test_caldav_connection(client,
        error_formatter: &zimbra_error_formatter/1
      )
    end
  end

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def new(config) do
    CaldavCommon.build_client(
      %{
        base_url: normalize_base_url(config[:base_url]),
        username: config[:username],
        password: config[:password],
        calendar_paths: build_zimbra_calendar_paths(config),
        verify_ssl: true,
        connection_timeout: config[:connection_timeout] || 10_000,
        request_timeout: config[:request_timeout] || 30_000,
        discovery_timeout: config[:discovery_timeout] || 15_000
      },
      provider: :zimbra
    )
  end

  @doc """
  Tests connection to Zimbra server with Zimbra-specific messaging.
  """
  @spec test_connection(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def test_connection(integration, opts \\ []) do
    ProviderCommon.test_caldav_provider_connection(integration,
      metadata: opts[:metadata],
      success_message: "Zimbra connection successful",
      unauthorized_message: "Authentication failed. Check your Zimbra username and password.",
      not_found_message: "Zimbra server not found. Check your server URL.",
      error_formatter: &format_error/1
    )
  end

  @doc """
  Discovers available calendars on the Zimbra server.
  """
  @spec discover_calendars(map(), keyword()) :: {:ok, list(map())} | {:error, String.t()}
  def discover_calendars(client, opts \\ []) do
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    # Ensure provider is set to zimbra for proper discovery URL
    client = Map.put(client, :provider, :zimbra)

    CaldavCommon.discover_calendars(client, ip_address: ip_address)
  end

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def get_events(client), do: CaldavCommon.get_events(client)

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def get_events(client, start_time, end_time),
    do: CaldavCommon.get_events(client, start_time, end_time)

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def create_event(client, event_data), do: CaldavCommon.create_event(client, event_data)

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
  def update_event(client, uid, event_data),
    do: CaldavCommon.update_event(client, uid, event_data)

  @impl Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour
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

  defp build_zimbra_calendar_paths(config) do
    # If calendar_paths is provided (from operations.ex for fetching), use it directly
    # Otherwise, build from calendar_names (for initial setup/discovery)
    case config[:calendar_paths] do
      paths when is_list(paths) and paths != [] ->
        paths

      _ ->
        build_zimbra_default_paths(config)
    end
  end

  defp zimbra_error_formatter(reason),
    do: ErrorHandler.sanitize_error_message(reason, :zimbra)

  defp build_zimbra_default_paths(config) do
    username = config[:username]
    calendar_names = config[:calendar_names] || []

    if Enum.empty?(calendar_names) do
      []
    else
      Enum.map(calendar_names, &format_zimbra_path(&1, username))
    end
  end

  defp format_zimbra_path(calendar_name, username) do
    if String.starts_with?(calendar_name, "/dav/#{username}/") do
      calendar_name
    else
      "/dav/#{username}/#{calendar_name}/"
    end
  end

  defp format_error({:error, message}) when is_binary(message), do: message
  defp format_error(error), do: "Zimbra error: #{inspect(error)}"
end
