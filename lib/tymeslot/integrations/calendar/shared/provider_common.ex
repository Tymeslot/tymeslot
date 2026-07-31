defmodule Tymeslot.Integrations.Calendar.Shared.ProviderCommon do
  @moduledoc """
  Utilities shared across calendar provider implementations.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Security.UrlValidation

  @doc """
  Ensures all required fields are present in the config map.
  """
  @spec validate_required_fields(%{atom() => term()}, list(atom())) :: :ok | {:error, String.t()}
  def validate_required_fields(config, required_fields) do
    missing_fields = required_fields -- Map.keys(config)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  @doc """
  Validates a calendar server URL for format and SSRF safety.

  Beyond requiring a well-formed http/https URL with a host, this rejects
  plain HTTP for public hosts and any URL pointing at a private, loopback, or
  link-local address — matching the persistence posture in
  `CalendarIntegrationSchema` (`block_private_ips: true`). An authenticated
  user must not be able to probe internal hosts via a provider's
  connection/discovery test any more than they can save such a URL.

  The private-IP block can be lifted for trusted in-process callers (e.g.
  integration tests against a local server) by either passing
  `allow_private_ips: true` in `opts` or setting the application config key
  `config :tymeslot, :allow_private_ips_for_calendar, true`. The production
  default is `false` in both cases.
  """
  @spec validate_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_url(url, opts \\ []) do
    invalid_message = Keyword.get(opts, :message, "Invalid URL format")

    allow_private =
      Keyword.get(
        opts,
        :allow_private_ips,
        Application.get_env(:tymeslot, :allow_private_ips_for_calendar, false)
      )

    UrlValidation.validate_http_url(url,
      invalid_message: invalid_message,
      disallowed_protocol_error: invalid_message,
      enforce_https_for_public: true,
      block_private_ips: not allow_private,
      https_error_message: "Use HTTPS for non-local calendar servers",
      private_ip_error_message: "Private or local network addresses are not allowed"
    )
  end

  @doc """
  Helper for providers to format calendars returned from their API.

  `mapper` normalises each raw provider calendar into a `CalendarEntry`
  struct, so this always returns the canonical discovery shape.
  """
  @spec discover_calendars(
          CalendarIntegrationSchema.t(),
          (CalendarIntegrationSchema.t() -> {:ok, [map()]} | {:error, term()}),
          (map() -> CalendarEntry.t())
        ) ::
          {:ok, [CalendarEntry.t()]} | {:error, term()}
  def discover_calendars(integration, list_fun, mapper) do
    case list_fun.(integration) do
      {:ok, calendars} -> {:ok, Enum.map(calendars, mapper)}
      {:error, reason, _detail} -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Tests connection to a CalDAV server with provider-specific error messages.

  This helper encapsulates the common pattern used by CalDAV-based providers
  (Radicale, Zimbra, Nextcloud, etc.) for testing connections.

  ## Options
    * `:success_message` - Message to return on successful connection
    * `:unauthorized_message` - Message to return on authentication failure
    * `:not_found_message` - Message to return when server not found
    * `:error_formatter` - Function to format other errors (receives reason, returns string)
  """
  @spec test_caldav_provider_connection(
          %{
            required(:base_url) => String.t(),
            required(:username) => String.t() | nil,
            required(:password) => String.t() | nil,
            required(:calendar_paths) => [String.t()] | nil,
            required(:provider) => atom()
          },
          keyword()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  def test_caldav_provider_connection(integration, opts \\ []) do
    success_msg = Keyword.fetch!(opts, :success_message)
    unauthorized_msg = Keyword.fetch!(opts, :unauthorized_message)
    not_found_msg = Keyword.fetch!(opts, :not_found_message)
    error_formatter = Keyword.fetch!(opts, :error_formatter)

    client = %{
      base_url: integration.base_url,
      username: integration.username,
      password: integration.password,
      calendar_paths: integration.calendar_paths || [],
      verify_ssl: true,
      provider: normalize_provider(integration.provider)
    }

    case CaldavCommon.test_connection(client) do
      {:ok, _response} ->
        {:ok, success_msg}

      {:error, :unauthorized} ->
        {:error, unauthorized_msg}

      {:error, :forbidden} ->
        {:error, error_formatter.(:forbidden)}

      {:error, :not_found} ->
        {:error, not_found_msg}

      {:error, reason} ->
        {:error, error_formatter.(reason)}
    end
  end

  @doc """
  Common implementation of `discover_calendars_for_integration/1` for
  CalDAV-based providers that store encrypted credentials.

  Decrypts the integration's username/password, builds a config map, and
  calls `provider_module.new/1` + `provider_module.discover_calendars/1`.
  Used by Radicale, Zimbra, MailboxOrg, Apple, and Baikal — providers whose
  discovery shim is otherwise identical apart from the module being
  dispatched to.

  Pure I/O — rate limiting and caching this call is the caller's job
  (`Tymeslot.Integrations.Calendar.Discovery`, the single choke point that
  wraps every CalDAV provider's `discover_calendars_for_integration/1`),
  not this shim's.
  """
  @spec caldav_discover_from_integration(module(), map()) ::
          {:ok, [CalendarEntry.t()]} | {:error, term()}
  def caldav_discover_from_integration(provider_module, integration) do
    decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

    config = %{
      base_url: integration.base_url,
      username: decrypted.username,
      password: decrypted.password,
      calendar_paths: integration.calendar_paths
    }

    provider_module.discover_calendars(provider_module.new(config))
  end

  @doc """
  Returns one CalDAV client config per selected calendar path on the
  integration. Drives the multi-calendar sync/fetch path in `ClientManager`.

  Honors `integration.calendar_list` selection when present, falling back to
  `integration.calendar_paths` (the legacy path-only representation).
  Read-only entries are skipped.
  """
  @spec caldav_build_client_configs(map()) :: [map()]
  def caldav_build_client_configs(integration) do
    integration
    |> caldav_selected_paths()
    |> Enum.map(&caldav_path_config(integration, &1))
  end

  @doc """
  Returns a single CalDAV client config for the booking flow, scoped to the
  path resolved by `CalendarPathResolver`. Returns `nil` when no path is
  resolvable for the integration.
  """
  @spec caldav_build_booking_client_config(map()) :: map() | nil
  def caldav_build_booking_client_config(integration) do
    case CalendarPathResolver.resolve(integration) do
      nil -> nil
      path -> caldav_path_config(integration, path)
    end
  end

  defp caldav_selected_paths(integration) do
    if integration.calendar_list && integration.calendar_list != [] do
      integration.calendar_list
      |> Selection.writable_calendars()
      |> Enum.map(&(&1.path || &1.id))
      |> Enum.reject(&is_nil/1)
    else
      integration.calendar_paths || []
    end
  end

  defp caldav_path_config(integration, path) do
    %{
      base_url: integration.base_url,
      username: integration.username,
      password: integration.password,
      calendar_path: path,
      calendar_paths: [path],
      verify_ssl: true
    }
  end

  defp normalize_provider(provider) when is_atom(provider), do: provider

  defp normalize_provider(provider) when is_binary(provider),
    do: String.to_existing_atom(provider)
end
