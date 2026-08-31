defmodule Tymeslot.Integrations.Calendar.Nextcloud.Provider do
  @moduledoc """
  Nextcloud-specific calendar provider implementation.

  This provider extends the generic CalDAV implementation with Nextcloud-specific
  URL patterns, authentication methods, and configuration defaults.

  Nextcloud uses CalDAV under the hood but has specific URL structures:
  - Base CalDAV endpoint: /remote.php/dav/
  - Calendar discovery: /remote.php/dav/calendars/{username}/
  - Individual calendars: /remote.php/dav/calendars/{username}/{calendar-name}/
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{DiscoveryService, PathUtils, ProviderCommon}

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :nextcloud

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Nextcloud"

  @impl Tymeslot.Integrations.Calendar.Provider
  def connection_test_bucket, do: :nextcloud

  @doc "Returns the LiveComponent module for provider configuration UI"
  @spec setup_component() :: module()
  def setup_component, do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.NextcloudConfig

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        description: "Nextcloud server URL (e.g., https://cloud.example.com)"
      },
      username: %{
        type: :string,
        required: true,
        description: "Nextcloud username"
      },
      password: %{
        type: :string,
        required: true,
        description: "Nextcloud password or app password"
      },
      calendar_paths: %{
        type: :list,
        required: false,
        description: "List of calendar names to sync (default: personal)"
      }
    }
  end

  # Structural validation only, in line with every other provider's
  # `validate_config/1`: the caller that needs connectivity
  # (`Calendar.Creation.prevalidate_config/1`) invokes `validate_config/1` first
  # and then `perform_connection_test/1`. This used to run its own connectivity probe
  # (by calling `perform_connection_test/1` internally), which doubled every rate-limit
  # charge — one for `validate_config`, one for the real test — across two
  # separate buckets.
  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    # Trim credentials so whitespace-only values count as missing rather than
    # leaking into CaldavCommon.validate_credentials/1 as {:error, :invalid_credentials}.
    config =
      config
      |> maybe_extract_username_from_url()
      |> trim_credentials()

    is_calendar_url = PathUtils.nextcloud_calendar_url?(config[:base_url] || "")

    required_fields =
      if is_calendar_url do
        [:base_url, :password]
      else
        [:base_url, :username, :password]
      end

    missing_fields = Enum.filter(required_fields, &blank?(config[&1]))

    cond do
      !Enum.empty?(missing_fields) ->
        {:error,
         dgettext("dashboard_calendar_providers", "Missing required fields: %{fields}",
           fields: Enum.join(missing_fields, ", ")
         )}

      !valid_nextcloud_url?(config[:base_url]) ->
        {:error,
         dgettext(
           "dashboard_calendar_providers",
           "Invalid Nextcloud URL. Should be your Nextcloud server URL (e.g., https://cloud.example.com) or calendar URL"
         )}

      true ->
        :ok
    end
  end

  defp trim_credentials(config) do
    config
    |> maybe_trim(:username)
    |> maybe_trim(:password)
  end

  defp maybe_trim(config, key) do
    case Map.get(config, key) do
      value when is_binary(value) -> Map.put(config, key, String.trim(value))
      _other -> config
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  @impl Tymeslot.Integrations.Calendar.Provider
  def new(config) do
    # Extract username from URL if it's a calendar URL
    config = maybe_extract_username_from_url(config)

    # Convert Nextcloud config to CalDAV config with Nextcloud-specific paths
    caldav_config = %{
      base_url: normalize_base_url(config[:base_url]),
      username: config[:username],
      password: config[:password],
      calendar_paths: build_nextcloud_calendar_paths(config),
      verify_ssl: true,
      provider: :nextcloud
    }

    CalDAVProvider.new(caldav_config)
  end

  @doc """
  Tests connection to Nextcloud server using CalDAV discovery.

  Builds the CalDAV client with the same URL normalisation used at setup time
  (`PathUtils.normalize_url/2` with `provider: :nextcloud`), so a `base_url`
  stored without `/remote.php/dav` — the format produced by `Creation.prepare_attrs`
  — still resolves to a valid CalDAV principal URL. Without this the discovery
  probe targets `\#{base_url}/calendars/\#{username}/`, which Nextcloud answers
  with HTTP 405 because that path is not WebDAV-mounted.

  Pure I/O — the caller (`Tymeslot.Integrations.Calendar.Connection`) decides
  whether and to whom the test is rate-limited.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec perform_connection_test(map()) :: {:ok, String.t()} | {:error, term()}
  def perform_connection_test(integration) do
    client = %{
      base_url:
        PathUtils.normalize_url(integration.base_url || "",
          provider: :nextcloud,
          ensure_trailing_slash: false
        ),
      username: integration.username,
      password: integration.password,
      calendar_paths: integration.calendar_paths || [],
      verify_ssl: true,
      provider: :nextcloud
    }

    case CaldavCommon.test_connection(client) do
      {:ok, _message} ->
        {:ok, dgettext("dashboard_calendar_providers", "Nextcloud connection successful")}

      {:error, :unauthorized} ->
        {:error,
         dgettext(
           "dashboard_calendar_providers",
           "Authentication failed. Check your Nextcloud username and password. Consider using an app password."
         )}

      {:error, :not_found} ->
        {:error,
         dgettext(
           "dashboard_calendar_providers",
           "Nextcloud server not found or CalDAV endpoint not accessible. Check your server URL."
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Discovers available calendars on the Nextcloud server.

  Delegates to `CaldavCommon.discover_calendars/1`, the same shared path every
  other CalDAV-family provider uses, so Nextcloud discovery gets the SSRF guard
  (`UrlValidation.validate_http_url/2` with `block_private_ips: true` and
  `enforce_https_for_public: true`), the circuit breaker, and normalised
  errors for free — Nextcloud's `base_url` is user-editable from the reconnect
  modal, so it cannot be trusted without that guard.

  Pure I/O — rate limiting and caching discovery is the caller's job
  (`Tymeslot.Integrations.Calendar.Discovery`), not this provider's.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec discover_calendars(map()) :: {:ok, list(map())} | {:error, term()}
  def discover_calendars(client) do
    client = Map.put(client, :provider, :nextcloud)
    CaldavCommon.discover_calendars(client)
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration) do
    # Pure I/O — rate limiting and caching this call is the caller's job
    # (`Tymeslot.Integrations.Calendar.Discovery`), not this provider's.
    # Still emits standardized calendar entries
    # (id/path/name/type/selected/provider/metadata) via
    # `DiscoveryService.standardize_calendar_data/2`, since raw Nextcloud
    # discovery returns unstandardized maps parsed from the PROPFIND response.
    decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

    config = %{
      base_url: integration.base_url,
      username: decrypted.username,
      password: decrypted.password,
      calendar_paths: integration.calendar_paths
    }

    case discover_calendars(new(config)) do
      {:ok, calendars} ->
        {:ok, DiscoveryService.standardize_calendar_data(calendars, :nextcloud)}

      error ->
        error
    end
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
  defdelegate normalise_events(raw_events, context), to: CalDAVProvider

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate check_connectivity(client), to: CaldavCommon

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(client, opts), do: CaldavCommon.list_events(client, opts)

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events_representation, do: :raw

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate create_event(client, event_data), to: CalDAVProvider

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate update_event(client, uid, event_data), to: CalDAVProvider

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(client, uid, opts \\ []), do: CalDAVProvider.delete_event(client, uid, opts)

  # Private helper functions

  defp valid_nextcloud_url?(url) when is_binary(url) do
    # First normalize the URL to ensure it has a scheme
    normalized = PathUtils.ensure_scheme(url)
    uri = URI.parse(normalized)

    # Now check if it's valid
    uri.scheme in ["http", "https"] and uri.host != nil
  end

  defp valid_nextcloud_url?(_url), do: false

  defp maybe_extract_username_from_url(config) do
    url = config[:base_url] || ""

    # If URL contains calendar path and no username provided, try to extract it
    if PathUtils.nextcloud_calendar_url?(url) and is_nil(config[:username]) do
      case PathUtils.extract_nextcloud_username(url) do
        {:ok, username} ->
          Map.put(config, :username, username)

        :error ->
          config
      end
    else
      config
    end
  end

  defp normalize_base_url(url) do
    # Use shared PathUtils for Nextcloud-specific URL normalization
    PathUtils.normalize_url(url, provider: :nextcloud, ensure_trailing_slash: false)
  end

  # `UrlBuilder.build_calendar_url/2` resolves a leading slash as
  # server-root-relative, against the origin alone, and anything else against
  # `base_url`, which by this point ends in the instance's DAV endpoint. Both
  # shapes reach here, so which one is produced decides where every read and
  # write actually lands.
  #
  # Discovery stores the server's own hrefs, and those already carry whatever
  # prefix the instance is served from: `/remote.php/dav/calendars/{user}/{cal}/`
  # at the domain root, `/nextcloud/remote.php/dav/...` on a subdirectory
  # install. Testing them against a fixed list of leading paths recognised only
  # the domain-root spellings, so a subdirectory href fell through to the
  # bare-name branch and was concatenated whole into the middle of a new path.
  # Every root-relative path now passes through untouched: the server has
  # already said where the collection lives, and nothing here can improve on it.
  #
  # A bare calendar name is the only shape left to build, and it is relative to
  # the DAV endpoint rather than to the origin, so it is deliberately returned
  # without a leading slash. Anchoring it at the root dropped `/remote.php/dav`
  # on every install, subdirectory or not.
  defp build_nextcloud_calendar_paths(config) do
    username = config[:username]
    # calendar_paths might come from the database integration
    calendar_paths = config[:calendar_paths] || ["personal"]

    Enum.map(calendar_paths, fn
      "/" <> _rest = discovered_path -> discovered_path
      calendar_name -> "calendars/#{username}/#{calendar_name}/"
    end)
  end
end
