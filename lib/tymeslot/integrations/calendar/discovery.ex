defmodule Tymeslot.Integrations.Calendar.Discovery do
  @moduledoc """
  Calendar discovery functions for integrations and raw credentials.
  Standardizes provider-specific discovery flows.
  """

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Shared.{DiscoveryService, ErrorHandler}

  @doc """
  Discover calendars for an existing integration using provider-specific logic.
  Returns {:ok, calendars} with standardized entries.
  """
  @spec discover_calendars_for_integration(map()) :: {:ok, list()} | {:error, any()}
  def discover_calendars_for_integration(%{provider: provider} = integration) do
    case provider do
      "google" ->
        GoogleProvider.discover_calendars(integration)

      "outlook" ->
        OutlookProvider.discover_calendars(integration)

      "caldav" ->
        config = %{
          base_url: integration.base_url,
          username: integration.username,
          password: integration.password,
          calendar_paths: calendar_paths_or_empty(integration)
        }

        client = Tymeslot.Integrations.Calendar.CalDAV.Provider.new(config)
        Tymeslot.Integrations.Calendar.CalDAV.Provider.discover_calendars(client)

      "nextcloud" ->
        decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

        config = %{
          base_url: integration.base_url,
          username: decrypted.username,
          password: decrypted.password,
          calendar_paths: calendar_paths_or_empty(integration)
        }

        case DiscoveryService.discover_calendars(:nextcloud, config, force_refresh: true) do
          {:ok, calendars} ->
            standardized = DiscoveryService.standardize_calendar_data(calendars, :nextcloud)
            {:ok, standardized}

          error ->
            error
        end

      "radicale" ->
        decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

        config = %{
          base_url: integration.base_url,
          username: decrypted.username,
          password: decrypted.password,
          calendar_paths: calendar_paths_or_empty(integration)
        }

        client = Tymeslot.Integrations.Calendar.Radicale.Provider.new(config)
        Tymeslot.Integrations.Calendar.Radicale.Provider.discover_calendars(client)

      _unknown ->
        {:error, "Unknown provider: #{provider}"}
    end
  end

  @doc """
  Discover calendars using raw credentials before creating an integration.
  Returns {:ok, %{calendars: standardized, discovery_credentials: %{...}}} or {:error, message}.
  """
  @spec discover_calendars_for_credentials(
          atom() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, %{calendars: list(), discovery_credentials: map()}} | {:error, String.t()}
  def discover_calendars_for_credentials(provider, url, username, password, opts \\ []) do
    force_refresh = Keyword.get(opts, :force_refresh, false)

    case resolve_provider_atom(provider) do
      {:ok, provider_atom} ->
        with {:ok, provider_module} <- provider_module_for(provider_atom),
             client_config <- %{base_url: url, username: username, password: password},
             :ok <-
               (case provider_module.validate_config(client_config) do
                  :ok -> :ok
                  {:error, reason} -> {:error, {:validation, reason}}
                end),
             {:ok, calendars} <-
               (case DiscoveryService.discover_calendars(provider_atom, client_config,
                       force_refresh: force_refresh
                     ) do
                  {:ok, cals} -> {:ok, cals}
                  {:error, reason} -> {:error, {:discovery, reason}}
                end) do
          standardized = DiscoveryService.standardize_calendar_data(calendars, provider_atom)

          {:ok,
           %{
             calendars: standardized,
             discovery_credentials: %{url: url, username: username, password: password}
           }}
        else
          {:error, {:validation, reason}} ->
            {:error,
             ErrorHandler.format_provider_error(reason, provider_atom, %{operation: "validation"})}

          {:error, {:discovery, reason}} ->
            {:error,
             ErrorHandler.format_provider_error(reason, provider_atom, %{operation: "discovery"})}

          {:error, :unknown_provider} ->
            {:error, "Unknown provider: #{provider}"}
        end

      {:error, :unknown_provider} ->
        {:error, "Unknown provider: #{provider}"}
    end
  end

  @doc """
  Maybe perform discovery for CalDAV/Radicale attrs during creation and inject paths.
  Non-CalDAV providers pass through unchanged.

  This is a narrow helper used by creation flows to opportunistically set
  calendar_paths for CalDAV-like providers, deferring all actual
  discovery logic to providers and Shared.DiscoveryService.
  """
  @spec maybe_discover_calendars(map()) :: {:ok, map()}
  def maybe_discover_calendars(%{"provider" => provider} = attrs)
      when provider in ["caldav", "radicale"] do
    case discover_caldav_calendar_paths(attrs) do
      {:ok, paths} when is_list(paths) and paths != [] ->
        {:ok, Map.put(attrs, "calendar_paths", paths)}

      _ ->
        {:ok, attrs}
    end
  end

  def maybe_discover_calendars(attrs), do: {:ok, attrs}

  defp calendar_paths_or_empty(%{calendar_paths: paths}) when is_list(paths), do: paths
  defp calendar_paths_or_empty(_), do: []

  # Internal helper that returns just the list of paths for CalDAV/Radicale
  @spec discover_caldav_calendar_paths(map()) :: {:ok, list(String.t())} | {:error, String.t()}
  defp discover_caldav_calendar_paths(%{"provider" => provider} = config) do
    provider_atom =
      case ProviderRegistry.validate_provider(provider) do
        {:ok, atom} -> atom
        _ -> :unknown
      end

    with true <- provider_atom != :unknown,
         {:ok, provider_module} <- ProviderRegistry.get_provider(provider_atom),
         client = provider_module.new(config),
         {:ok, calendars} <- provider_module.discover_calendars(client) do
      {:ok, extract_calendar_paths(calendars)}
    else
      {:error, reason} -> {:error, format_discovery_error(reason)}
      _ -> {:ok, []}
    end
  end

  defp discover_caldav_calendar_paths(_), do: {:ok, []}

  defp resolve_provider_atom(p) do
    case ProviderRegistry.validate_provider(p) do
      {:ok, provider_atom} -> {:ok, provider_atom}
      {:error, _} -> {:error, :unknown_provider}
    end
  end

  defp provider_module_for(provider_atom) do
    case ProviderRegistry.get_provider(provider_atom) do
      {:ok, mod} -> {:ok, mod}
      {:error, _} -> {:error, :unknown_provider}
    end
  end

  # Helpers migrated from legacy discovery context
  defp extract_calendar_paths(calendars) when is_list(calendars) do
    calendars
    |> Enum.map(fn
      %{href: href} -> href
      %{"href" => href} -> href
      %{"path" => path} -> path
      %{path: path} -> path
      path when is_binary(path) -> path
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_calendar_paths(_), do: []

  defp format_discovery_error(:unauthorized), do: "Authentication failed during discovery"
  defp format_discovery_error(:not_found), do: "Calendar server not found"
  defp format_discovery_error(:network_error), do: "Network error during discovery"
  defp format_discovery_error(reason) when is_binary(reason), do: reason
  defp format_discovery_error(_), do: "Calendar discovery failed"
end
