defmodule Tymeslot.Integrations.Calendar.Zimbra.Provider do
  @moduledoc """
  Zimbra provider that leverages the shared CalDAV base module.

  Zimbra uses CalDAV for calendar access with the standard path pattern:
  /dav/{username}/ for calendar discovery.

  This provider is a thin configuration layer over the base CalDAV
  implementation, providing Zimbra-specific defaults and messaging.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}
  alias Tymeslot.Security.UrlValidation

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :zimbra

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Zimbra"

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.ZimbraConfig

  @impl Tymeslot.Integrations.Calendar.Provider
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

  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    with :ok <- ProviderCommon.validate_required_fields(config, [:base_url, :username, :password]),
         :ok <- validate_zimbra_url(config[:base_url]),
         {:ok, client} <- build_test_client(config) do
      ProviderCommon.test_caldav_connection(client,
        error_formatter: &zimbra_error_formatter/1
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

  defp validate_zimbra_url(url) do
    case UrlValidation.validate_http_url(url,
           enforce_https_for_public: true,
           https_error_message: "Use HTTPS for non-local Zimbra servers",
           invalid_message:
             "Invalid Zimbra URL. Should be your Zimbra server URL (e.g., https://mail.example.com) or full CalDAV URL (e.g., https://mail.example.com/dav/user@example.com)"
         ) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

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

      _other ->
        build_zimbra_default_paths(config)
    end
  end

  defp zimbra_error_formatter(reason),
    do: ErrorHandler.sanitize_error_message(reason, :zimbra)

  defp build_zimbra_default_paths(config) do
    username = config[:username]
    calendar_names = config[:calendar_names] || []

    if Enum.empty?(calendar_names) or not is_binary(username) or username == "" do
      []
    else
      calendar_names
      |> Enum.map(&format_zimbra_path(&1, username))
      |> Enum.reject(&is_nil(&1))
    end
  end

  defp format_zimbra_path(calendar_name, username)
       when is_binary(calendar_name) and is_binary(username) and username != "" do
    # Sanitize both calendar_name and username to prevent path traversal
    sanitized_name = sanitize_calendar_name(calendar_name)
    sanitized_username = sanitize_username(username)

    if sanitized_name == "" or sanitized_username == "" do
      nil
    else
      # Build path from sanitized inputs to prevent path traversal attacks
      path = "/dav/#{sanitized_username}/#{sanitized_name}/"

      # Validate path length (max 255 bytes for filesystem compatibility)
      # Use byte_size instead of String.length to account for multi-byte UTF-8 characters
      if byte_size(path) > 255 do
        nil
      else
        path
      end
    end
  end

  defp format_zimbra_path(_calendar_name, _username), do: nil

  # Sanitizes calendar name input to prevent security vulnerabilities.
  #
  # Removes dangerous patterns that could be exploited for:
  # - Path traversal attacks (../ sequences)
  # - Directory traversal (leading/trailing slashes)
  # - Null byte injection (\x00)
  # - Control character injection (\x00-\x1F, \x7F)
  #
  # Also enforces reasonable length limits to prevent DoS attacks.
  #
  # Examples:
  #   sanitize_calendar_name("../../../etc/passwd") => "etcpasswd"
  #   sanitize_calendar_name("Calendar\x00Name") => "CalendarName"
  #   sanitize_calendar_name("  /Valid Calendar/  ") => "Valid Calendar"
  defp sanitize_calendar_name(name) do
    name
    # Hard limit on input size first to prevent DoS via extremely long strings
    |> String.slice(0, 1000)
    |> String.trim()
    # Remove path traversal sequences (.., ..., etc.)
    |> String.replace(~r/\.\.+/, "")
    # Remove leading/trailing slashes from name component
    |> String.trim("/")
    # Remove null bytes and control characters
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
    # Ensure reasonable output length
    |> String.slice(0, 200)
  end

  # Sanitizes username input to prevent path traversal and injection attacks.
  #
  # The username is used in CalDAV path construction (/dav/{username}/{calendar}/),
  # so it must be sanitized to prevent attackers from escaping the user directory
  # or injecting malicious path components.
  #
  # Applies the same security controls as calendar name sanitization.
  #
  # Examples:
  #   sanitize_username("user@example.com/../../etc") => "user@example.cometc"
  #   sanitize_username("user\x00@example.com") => "user@example.com"
  defp sanitize_username(username) do
    username
    # Hard limit on input size first to prevent DoS
    |> String.slice(0, 1000)
    |> String.trim()
    # Remove path traversal sequences
    |> String.replace(~r/\.\.+/, "")
    # Remove leading/trailing slashes
    |> String.trim("/")
    # Remove null bytes and control characters
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
    # Ensure reasonable output length
    |> String.slice(0, 200)
  end

  defp format_error(error), do: ErrorHandler.sanitize_error_message(error, :zimbra)
end
