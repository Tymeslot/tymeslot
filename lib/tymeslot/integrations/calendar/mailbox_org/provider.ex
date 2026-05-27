defmodule Tymeslot.Integrations.Calendar.MailboxOrg.Provider do
  @moduledoc """
  mailbox.org provider that leverages the shared CalDAV base module.

  mailbox.org runs Open-Xchange and exposes calendars under a fixed
  `/caldav/` calendar-home-set. Calendar paths are server-issued opaque
  base64 identifiers, so this module never builds a path from user input —
  paths come from discovery only.

  Two operational notes that differ from other CalDAV providers:

  * Open-Xchange returns `201 Created` for both creates *and* updates and
    omits `ETag` on PUT responses. The shared layer already accepts
    `[200, 201, 204]` and re-fetches the ETag via HEAD/GET when needed.
  * Users with two-factor authentication must use an application-specific
    password generated under `Settings → Security`.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}
  alias Tymeslot.Security.UrlValidation

  @default_base_url "https://dav.mailbox.org"

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :mailbox_org

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "mailbox.org"

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.MailboxOrgConfig

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        default: @default_base_url,
        description: "mailbox.org CalDAV server URL (default: https://dav.mailbox.org)"
      },
      username: %{
        type: :string,
        required: true,
        description: "mailbox.org email address (e.g. you@mailbox.org)"
      },
      password: %{
        type: :string,
        required: true,
        description:
          "mailbox.org password — or an application-specific password if 2FA is enabled"
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
         :ok <- validate_mailbox_url(config[:base_url]),
         {:ok, client} <- build_test_client(config) do
      ProviderCommon.test_caldav_connection(client,
        error_formatter: &mailbox_error_formatter/1
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
      provider: :mailbox_org
    )
  end

  @doc """
  Tests connection to a mailbox.org account with provider-specific messaging.
  """
  @spec test_connection(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def test_connection(integration, opts \\ []) do
    ProviderCommon.test_caldav_provider_connection(integration,
      metadata: opts[:metadata],
      success_message: "mailbox.org connection successful",
      unauthorized_message:
        "Authentication failed. If 2FA is enabled, generate an application-specific password in mailbox.org Settings → Security.",
      not_found_message:
        "mailbox.org CalDAV endpoint not found. Confirm the server URL is https://dav.mailbox.org",
      error_formatter: &format_error/1
    )
  end

  @doc """
  Discovers available calendars on the mailbox.org account.
  """
  @spec discover_calendars(map(), keyword()) :: {:ok, list(map())} | {:error, String.t()}
  def discover_calendars(client, opts \\ []) do
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"
    client = Map.put(client, :provider, :mailbox_org)
    CaldavCommon.discover_calendars(client, ip_address: ip_address)
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration),
    do: ProviderCommon.caldav_discover_from_integration(__MODULE__, integration)

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

  defp validate_mailbox_url(url) do
    UrlValidation.validate_http_url(url,
      enforce_https_for_public: true,
      https_error_message: "mailbox.org requires HTTPS",
      invalid_message:
        "Invalid mailbox.org URL. Use https://dav.mailbox.org (or your custom mailbox.org-compatible CalDAV endpoint)."
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

  defp mailbox_error_formatter(reason),
    do: ErrorHandler.sanitize_error_message(reason, :mailbox_org)

  defp format_error(error), do: ErrorHandler.sanitize_error_message(error, :mailbox_org)
end
