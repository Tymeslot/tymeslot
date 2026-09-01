defmodule Tymeslot.Integrations.Calendar.Baikal.Provider do
  @moduledoc """
  Baikal provider that leverages the shared CalDAV base module.

  Baikal is a PHP-based CalDAV/CardDAV server. It exposes CalDAV through a
  `/dav.php` endpoint and stores calendars under
  `/dav.php/calendars/USERNAME/CALENDAR/`.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :baikal

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Baikal"

  @impl Tymeslot.Integrations.Calendar.Provider
  def connection_test_bucket, do: :caldav

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.BaikalConfig

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        description: "Baikal server URL (e.g., https://baikal.example.com/dav.php)"
      },
      username: %{
        type: :string,
        required: true,
        description: "Baikal username"
      },
      password: %{
        type: :string,
        required: true,
        description: "Baikal password"
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

  # Structural validation only, in line with every other provider's
  # `validate_config/1`: the caller that needs connectivity
  # (`Calendar.Creation.prevalidate_config/1`) invokes `validate_config/1` first
  # and then `perform_connection_test/1`. Folding a connectivity probe into this
  # callback would double-charge a rate-limited connection test that runs both
  # in sequence.
  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    with :ok <- ProviderCommon.validate_required_fields(config, [:base_url, :username, :password]) do
      ProviderCommon.validate_url(config[:base_url],
        message:
          dgettext(
            "dashboard_calendar_providers",
            "Invalid Baikal URL. Should be your Baikal server URL including /dav.php (e.g., https://baikal.example.com/dav.php)"
          )
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
        calendar_paths: build_baikal_calendar_paths(config),
        verify_ssl: true,
        connection_timeout: config[:connection_timeout] || 10_000,
        request_timeout: config[:request_timeout] || 30_000,
        discovery_timeout: config[:discovery_timeout] || 15_000
      },
      provider: :baikal
    )
  end

  @doc """
  Tests connection to the Baikal server with Baikal-specific messaging.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec perform_connection_test(map()) :: {:ok, String.t()} | {:error, String.t()}
  def perform_connection_test(integration) do
    ProviderCommon.test_caldav_provider_connection(integration,
      success_message: dgettext("dashboard_calendar_providers", "Baikal connection successful"),
      unauthorized_message:
        dgettext(
          "dashboard_calendar_providers",
          "Authentication failed. Check your Baikal username and password."
        ),
      not_found_message:
        dgettext(
          "dashboard_calendar_providers",
          "Baikal server not found. Confirm the URL includes /dav.php (e.g., https://baikal.example.com/dav.php)."
        ),
      error_formatter: &format_error/1
    )
  end

  @doc """
  Discovers available calendars on the Baikal server.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec discover_calendars(map()) :: {:ok, [CalendarEntry.t()]} | {:error, String.t()}
  def discover_calendars(client) do
    client = Map.put(client, :provider, :baikal)
    CaldavCommon.discover_calendars(client)
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
  def list_events_representation, do: :raw

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(raw_events, context),
    do: EventProcessor.normalise_events(raw_events, context)

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(client), do: CaldavCommon.check_connectivity(client)

  # Private helpers

  defp normalize_base_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp build_baikal_calendar_paths(config) do
    case config[:calendar_paths] do
      paths when is_list(paths) and paths != [] ->
        paths

      _other ->
        build_baikal_default_paths(config)
    end
  end

  defp build_baikal_default_paths(config) do
    username = config[:username]
    calendar_names = config[:calendar_names] || []

    if Enum.empty?(calendar_names) do
      []
    else
      Enum.map(calendar_names, &format_baikal_path(&1, username))
    end
  end

  defp format_baikal_path(calendar_name, username) do
    dav_prefix = "/dav.php/calendars/#{username}/"

    if String.starts_with?(calendar_name, dav_prefix) do
      calendar_name
    else
      "#{dav_prefix}#{calendar_name}/"
    end
  end

  defp format_error({:error, message}) when is_binary(message), do: message

  defp format_error(error),
    do:
      dgettext("dashboard_calendar_providers", "Baikal error: %{detail}", detail: inspect(error))
end
