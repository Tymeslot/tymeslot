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

  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{DiscoveryService, PathUtils, ProviderCommon}
  alias Tymeslot.Security.RateLimiter

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :nextcloud

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Nextcloud"

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
        {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}

      !valid_nextcloud_url?(config[:base_url]) ->
        {:error,
         "Invalid Nextcloud URL. Should be your Nextcloud server URL (e.g., https://cloud.example.com) or calendar URL"}

      true ->
        test_config = %{
          base_url: normalize_base_url(config[:base_url]),
          username: config[:username],
          password: config[:password],
          calendar_paths: config[:calendar_paths] || []
        }

        case test_connection(test_config) do
          {:ok, _message} -> :ok
          {:error, reason} -> {:error, reason}
        end
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

  `:rate_limit_scope` names who the test is charged to — `{:user, user_id}` for
  an interactive test, `{:integration, id}` for a scheduled health probe.
  """
  @spec test_connection(map(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def test_connection(integration, opts \\ []) do
    scope = rate_limit_scope(integration, opts)

    with :ok <- check_rate_limit(scope) do
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

      case CaldavCommon.test_connection(client, rate_limit_scope: scope) do
        {:ok, _message} ->
          {:ok, "Nextcloud connection successful"}

        {:error, :unauthorized} ->
          {:error,
           "Authentication failed. Check your Nextcloud username and password. Consider using an app password."}

        {:error, :not_found} ->
          {:error,
           "Nextcloud server not found or CalDAV endpoint not accessible. Check your server URL."}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Discovers available calendars on the Nextcloud server.
  """
  @spec discover_calendars(map(), Keyword.t()) :: {:ok, list(map())} | {:error, term()}
  def discover_calendars(client, opts \\ []) do
    # Extract IP address for rate limiting
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    with :ok <- check_discovery_rate_limit(ip_address) do
      # Use CalDAV PROPFIND to discover available calendars
      # client.base_url already includes /remote.php/dav from normalize_base_url
      discovery_url = "#{client.base_url}/calendars/#{client.username}/"

      headers = [
        {"Authorization", "Basic " <> Base.encode64("#{client.username}:#{client.password}")},
        {"Content-Type", "application/xml"},
        {"Depth", "1"}
      ]

      # Use shared XML builder for PROPFIND request
      propfind_body = XmlHandler.build_propfind_request()

      # Use Finch for custom PROPFIND method with timeout
      request = Finch.build("PROPFIND", discovery_url, headers, propfind_body)

      # Add a 10 second timeout to prevent hanging
      options = [receive_timeout: 10_000]

      case Finch.request(request, Tymeslot.Finch, options) do
        {:ok, %Finch.Response{status: 207, body: body}} ->
          parse_calendar_discovery_response(body)

        {:ok, %Finch.Response{status: status}} ->
          {:error, "Calendar discovery failed with status #{status}"}

        {:error, reason} ->
          {:error, "Network error during calendar discovery: #{inspect(reason)}"}
      end
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration) do
    # Nextcloud goes through DiscoveryService for its cache layer and emits
    # standardized calendar entries (id/path/name/type/selected/provider/metadata).
    decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

    config = %{
      base_url: integration.base_url,
      username: decrypted.username,
      password: decrypted.password,
      calendar_paths: integration.calendar_paths
    }

    case DiscoveryService.discover_calendars(:nextcloud, config, force_refresh: true) do
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

  defp build_nextcloud_calendar_paths(config) do
    username = config[:username]
    # calendar_paths might come from the database integration
    calendar_paths = config[:calendar_paths] || ["personal"]

    Enum.map(calendar_paths, fn calendar_name ->
      cond do
        # Already a full server-root-relative DAV path stored by discovery.
        String.starts_with?(calendar_name, "/remote.php/dav/") ->
          calendar_name

        # Already an absolute calendar path relative to /remote.php/dav
        String.starts_with?(calendar_name, "/calendars/") ->
          calendar_name

        # Bare calendar name — build the standard per-user path
        true ->
          "/calendars/#{username}/#{calendar_name}/"
      end
    end)
  end

  defp parse_calendar_discovery_response(xml_body) do
    # Use shared XML parser - Nextcloud doesn't need ID field by default
    XmlHandler.parse_calendar_discovery(xml_body,
      include_id: false,
      include_selected: false
    )
  end

  # Rate limiting helpers
  defp rate_limit_scope(integration, opts) do
    Keyword.get(opts, :rate_limit_scope) ||
      {:host, URI.parse(integration.base_url || "").host}
  end

  defp check_rate_limit(scope) do
    case RateLimiter.check_nextcloud_connection_rate_limit(scope) do
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
end
