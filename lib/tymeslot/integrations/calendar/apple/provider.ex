defmodule Tymeslot.Integrations.Calendar.Apple.Provider do
  @moduledoc """
  Apple iCloud provider that leverages the shared CalDAV base module.

  iCloud exposes calendars over CalDAV at the fixed host `caldav.icloud.com`.
  The server URL is therefore locked — users only supply their Apple ID email
  and an **app-specific password** (iCloud rejects the account password and
  requires a password generated at appleid.apple.com → Sign-In and Security →
  App-Specific Passwords).

  Two operational notes that differ from other CalDAV providers:

  * The guessed `/calendars/{user}/` discovery path returns `403`; iCloud only
    reveals calendars through the RFC 4791 principal chain, which the shared
    discovery layer follows automatically on a `403`.
  * `calendar-home-set` is returned as an absolute URL on a per-user partition
    host (e.g. `https://p110-caldav.icloud.com/…/calendars/`); the shared
    `UrlBuilder` reduces it to its path and pins it to the validated
    `caldav.icloud.com` host, which serves the same collections.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}
  alias Tymeslot.Security.UrlValidation

  @default_base_url "https://caldav.icloud.com"

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :apple

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Apple iCloud"

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.AppleConfig

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        default: @default_base_url,
        description: "Apple iCloud CalDAV server URL (always https://caldav.icloud.com)"
      },
      username: %{
        type: :string,
        required: true,
        description: "Apple ID email address (e.g. you@icloud.com)"
      },
      password: %{
        type: :string,
        required: true,
        description:
          "An app-specific password generated at appleid.apple.com — not your Apple ID password"
      },
      calendar_paths: %{
        type: :list,
        required: false,
        description: "List of calendar paths to sync (auto-discovered when omitted)"
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
         :ok <- validate_apple_url(config[:base_url]),
         {:ok, client} <- build_test_client(config) do
      ProviderCommon.test_caldav_connection(client,
        error_formatter: &apple_error_formatter/1
      )
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def new(config) do
    CaldavCommon.build_client(
      %{
        base_url: normalize_base_url(config[:base_url] || @default_base_url),
        username: config[:username],
        password: config[:password],
        calendar_paths: config[:calendar_paths] || [],
        verify_ssl: true,
        connection_timeout: config[:connection_timeout] || 10_000,
        request_timeout: config[:request_timeout] || 30_000,
        discovery_timeout: config[:discovery_timeout] || 15_000
      },
      provider: :apple
    )
  end

  @doc """
  Tests connection to an Apple iCloud account with provider-specific messaging.
  """
  @spec test_connection(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def test_connection(integration, opts \\ []) do
    ProviderCommon.test_caldav_provider_connection(integration,
      rate_limit_scope: opts[:rate_limit_scope],
      success_message: "Apple iCloud connection successful",
      unauthorized_message:
        "Authentication failed. iCloud requires an app-specific password — generate one at appleid.apple.com under Sign-In and Security, and use it instead of your Apple ID password.",
      not_found_message:
        "Apple iCloud CalDAV endpoint not found. The server URL must be https://caldav.icloud.com",
      error_formatter: &format_error/1
    )
  end

  @doc """
  Discovers available calendars on the Apple iCloud account.
  """
  @spec discover_calendars(map(), keyword()) :: {:ok, list(map())} | {:error, String.t()}
  def discover_calendars(client, opts \\ []) do
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"
    client = Map.put(client, :provider, :apple)
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

  # Private helpers

  defp validate_apple_url(url) do
    UrlValidation.validate_http_url(url,
      enforce_https_for_public: true,
      https_error_message: "Apple iCloud requires HTTPS",
      invalid_message: "Invalid Apple iCloud URL. The server must be https://caldav.icloud.com."
    )
  end

  defp build_test_client(config) do
    {:ok, new(config)}
  end

  defp normalize_base_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp apple_error_formatter(reason),
    do: ErrorHandler.sanitize_error_message(reason, :apple)

  defp format_error(error), do: ErrorHandler.sanitize_error_message(error, :apple)
end
