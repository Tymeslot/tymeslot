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

  @behaviour Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour

  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils
  alias Tymeslot.Security.RateLimiter

  @impl true
  def provider_type, do: :nextcloud

  @impl true
  def display_name, do: "Nextcloud"

  @impl true
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

  @impl true
  def validate_config(config) do
    # Extract username from URL if it's a calendar URL
    config = maybe_extract_username_from_url(config)

    # For calendar URLs, we need to handle them differently
    is_calendar_url = PathUtils.nextcloud_calendar_url?(config[:base_url] || "")

    required_fields =
      if is_calendar_url do
        # Username can be extracted from URL, so it's optional
        [:base_url, :password]
      else
        [:base_url, :username, :password]
      end

    missing_fields = required_fields -- Map.keys(config)

    cond do
      !Enum.empty?(missing_fields) ->
        {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}

      !valid_nextcloud_url?(config[:base_url]) ->
        {:error,
         "Invalid Nextcloud URL. Should be your Nextcloud server URL (e.g., https://cloud.example.com) or calendar URL"}

      true ->
        # All required fields present and URL is valid, now test the actual connection
        # Create a temporary integration-like map for test_connection
        test_config = %{
          base_url: normalize_base_url(config[:base_url]),
          username: config[:username],
          password: config[:password],
          calendar_paths: config[:calendar_paths] || []
        }

        case test_connection(test_config) do
          {:ok, _message} ->
            :ok

          {:error, reason} ->
            # All errors from test_connection should already be strings
            {:error, reason}
        end
    end
  end

  @impl true
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
  """
  @spec test_connection(map(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def test_connection(integration, opts \\ []) do
    # Extract IP address for rate limiting
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    with :ok <- check_rate_limit(ip_address) do
      # Use CalDAV provider but with Nextcloud-specific error messages
      case CalDAVProvider.test_connection(integration, opts) do
        {:ok, _message} ->
          {:ok, "Nextcloud connection successful"}

        {:error, :unauthorized} ->
          {:error,
           "Authentication failed. Check your Nextcloud username and password. Consider using an app password."}

        {:error, :not_found} ->
          {:error,
           "Nextcloud server not found or CalDAV endpoint not accessible. Check your server URL."}

        {:error, reason} ->
          # All other errors from CalDAVProvider.test_connection should be strings
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

  # Delegate CalDAV operations to the generic CalDAV provider
  @impl true
  defdelegate get_events(client), to: CalDAVProvider

  @impl true
  defdelegate get_events(client, start_time, end_time), to: CalDAVProvider

  @impl true
  defdelegate create_event(client, event_data), to: CalDAVProvider

  @impl true
  defdelegate update_event(client, uid, event_data), to: CalDAVProvider

  @impl true
  defdelegate delete_event(client, uid), to: CalDAVProvider

  # Private helper functions

  defp valid_nextcloud_url?(url) when is_binary(url) do
    # First normalize the URL to ensure it has a scheme
    normalized = PathUtils.ensure_scheme(url)
    uri = URI.parse(normalized)

    # Now check if it's valid
    uri.scheme in ["http", "https"] and uri.host != nil
  end

  defp valid_nextcloud_url?(_), do: false

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
      # If it's already a full path, use it; otherwise build the path
      if String.starts_with?(calendar_name, "/calendars/") do
        calendar_name
      else
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
  defp check_rate_limit(ip_address) do
    case RateLimiter.check_nextcloud_connection_rate_limit(ip_address) do
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
