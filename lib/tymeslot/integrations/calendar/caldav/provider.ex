defmodule Tymeslot.Integrations.Calendar.CalDAV.Provider do
  @moduledoc """
  Refactored CalDAV calendar provider using the shared base module.

  This is a cleaner implementation that delegates common CalDAV operations
  to the base module and focuses only on provider-specific configuration.

  The provider automatically detects known CalDAV server types (Radicale,
  Nextcloud, ownCloud, Baikal, SabreDAV) and adjusts path structures
  accordingly for proper authentication and discovery.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalDAV.ServerDetector
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon
  alias Tymeslot.Utils.MapKeys

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :caldav

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "CalDAV"

  @impl Tymeslot.Integrations.Calendar.Provider
  def connection_test_bucket, do: :caldav

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavConfig

  @impl Tymeslot.Integrations.Calendar.Provider
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

  # Structural validation only, in line with every other provider's
  # `validate_config/1`: the caller that needs connectivity
  # (`Calendar.Creation.prevalidate_config/1`) invokes `validate_config/1` first
  # and then `perform_connection_test/1`. Folding a connectivity probe into this
  # callback would double-charge a rate-limited connection test that runs both
  # in sequence.
  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    with :ok <- ProviderCommon.validate_required_fields(config, [:base_url, :username, :password]) do
      ProviderCommon.validate_url(config[:base_url])
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def new(config) do
    base_url = MapKeys.get(config, :base_url)

    # Auto-detect server type and use detected type for proper path construction
    detected_provider =
      if is_binary(base_url) do
        case ServerDetector.detect_from_url(base_url) do
          # Use detected server types for proper path handling
          server_type
          when server_type in [
                 :radicale,
                 :nextcloud,
                 :owncloud,
                 :baikal,
                 :baikal_legacy,
                 :sabredav,
                 :zimbra
               ] ->
            server_type

          # Fall back to generic caldav for unknown servers
          _other ->
            :caldav
        end
      else
        :caldav
      end

    common_config = %{
      base_url: if(is_binary(base_url), do: CaldavCommon.normalize_url(base_url), else: nil),
      username: MapKeys.get(config, :username),
      password: MapKeys.get(config, :password),
      calendar_paths: MapKeys.get(config, :calendar_paths) || [],
      verify_ssl: true
    }

    CaldavCommon.build_client(common_config, provider: detected_provider)
  end

  @doc """
  Tests connection to the CalDAV server.

  Pure I/O — the caller (`Tymeslot.Integrations.Calendar.Connection`) decides
  whether and to whom the test is rate-limited.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec perform_connection_test(map()) :: {:ok, String.t()} | {:error, atom() | String.t()}
  def perform_connection_test(integration) do
    client = build_client(integration)
    CaldavCommon.test_connection(client)
  end

  @doc """
  Discovers available calendars on the CalDAV server.

  Pure I/O — rate limiting and caching discovery is the caller's job
  (`Tymeslot.Integrations.Calendar.Discovery`), not this provider's.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec discover_calendars(map()) :: {:ok, [CalendarEntry.t()]} | {:error, String.t()}
  def discover_calendars(client) do
    CaldavCommon.discover_calendars(client)
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration) do
    # Generic CalDAV uses the integration's virtual username/password fields
    # directly — credentials reach this path already in plaintext from the
    # connection flow rather than via the encrypted-fields decrypt round-trip
    # used by Radicale/Zimbra/etc.
    config = %{
      base_url: integration.base_url,
      username: integration.username,
      password: integration.password,
      calendar_paths: integration.calendar_paths
    }

    # Pure I/O — rate limiting and caching this call is the caller's job
    # (`Tymeslot.Integrations.Calendar.Discovery`), not this provider's.
    discover_calendars(new(config))
  end

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

  # Private helper functions

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
