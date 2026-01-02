defmodule Tymeslot.Integrations.Video do
  @moduledoc """
  UI-agnostic facade for video integration business logic.

  Exposes a cohesive API used by web components without any LiveView/socket coupling.
  """

  # Database
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries

  # OAuth helpers
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper

  # Internal video components
  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Integrations.Video.Discovery
  alias Tymeslot.Integrations.Video.Rooms
  alias Tymeslot.Integrations.Video.Urls

  # Provider modules
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  alias TymeslotWeb.Endpoint

  @type provider :: :google_meet | :teams | :mirotalk | :custom | :none | String.t()

  # ---------------
  # Read
  # ---------------
  @spec list_integrations(pos_integer()) :: list()
  def list_integrations(user_id) when is_integer(user_id) do
    VideoIntegrationQueries.list_all_for_user(user_id)
  end

  # ---------------
  # Create
  # ---------------
  @spec create_integration(pos_integer(), provider(), map()) :: {:ok, any()} | {:error, any()}
  def create_integration(user_id, provider, attrs) when is_integer(user_id) and is_map(attrs) do
    provider = normalize_provider(provider)

    # Enforce provider in attrs consistently as string for DB layer
    attrs = Map.put(Map.put(attrs, :user_id, user_id), :provider, to_string(provider))

    do_create_integration(provider, attrs)
  end

  defp do_create_integration(:mirotalk, attrs) do
    # Pre-test the connection prior to creation for better UX
    config = %{
      api_key: attrs[:api_key] || attrs["api_key"],
      base_url: attrs[:base_url] || attrs["base_url"]
    }

    case ProviderRegistry.test_provider_connection(:mirotalk, config) do
      {:ok, _msg} -> VideoIntegrationQueries.create(attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  # OAuth providers are created after OAuth callback normally; allow manual create only for custom/mirotalk
  defp do_create_integration(provider, attrs)
       when provider in [:google_meet, :teams, :custom, :none] do
    VideoIntegrationQueries.create(attrs)
  end

  defp do_create_integration(_unknown, _attrs), do: {:error, :unknown_provider}

  # ---------------
  # Delete
  # ---------------
  @spec delete_integration(pos_integer(), pos_integer()) :: {:ok, :deleted} | {:error, any()}
  def delete_integration(user_id, id) when is_integer(user_id) do
    with {:ok, integration} <- VideoIntegrationQueries.get_for_user(id, user_id),
         {:ok, _} <- VideoIntegrationQueries.delete(integration) do
      {:ok, :deleted}
    else
      {:error, _} = err -> err
    end
  end

  # ---------------
  # Toggle active
  # ---------------
  @spec toggle_integration(pos_integer(), pos_integer()) :: {:ok, any()} | {:error, any()}
  def toggle_integration(user_id, id) when is_integer(user_id) do
    case VideoIntegrationQueries.get_for_user(id, user_id) do
      {:ok, integration} -> VideoIntegrationQueries.toggle_active(integration)
      {:error, _} = err -> err
    end
  end

  # ---------------
  # Set default
  # ---------------
  @spec set_default(pos_integer(), pos_integer()) :: {:ok, any()} | {:error, any()}
  def set_default(user_id, id) when is_integer(user_id) do
    case VideoIntegrationQueries.get_for_user(id, user_id) do
      {:ok, integration} -> VideoIntegrationQueries.set_as_default(integration)
      {:error, _} = err -> err
    end
  end

  # ---------------
  # Provider discovery helpers
  # ---------------
  @spec list_available_providers() :: list()
  def list_available_providers, do: Discovery.list_available_providers()

  @spec default_provider() :: atom()
  def default_provider, do: Discovery.default_provider()

  # ---------------
  # Connection
  # ---------------
  @spec test_connection(pos_integer(), pos_integer()) :: {:ok, String.t()} | {:error, any()}
  defdelegate test_connection(user_id, id), to: Connection

  # ---------------
  # Meeting room operations
  # ---------------
  @spec create_meeting_room(pos_integer() | nil) :: {:ok, map()} | {:error, any()}
  defdelegate create_meeting_room(user_id \\ nil), to: Rooms

  @spec create_join_url(map(), String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, any()}
  defdelegate create_join_url(
                meeting_context,
                participant_name,
                participant_email,
                role,
                meeting_time
              ),
              to: Rooms

  @spec handle_meeting_event(map(), atom(), map()) :: :ok | {:error, any()}
  defdelegate handle_meeting_event(meeting_context, event, additional_data \\ %{}), to: Rooms

  @spec generate_meeting_metadata(map()) :: map()
  defdelegate generate_meeting_metadata(meeting_context), to: Rooms

  # ---------------
  # URL helpers
  # ---------------
  @spec extract_room_id(String.t() | map()) :: String.t() | nil
  defdelegate extract_room_id(input), to: Urls

  @spec valid_meeting_url?(String.t()) :: boolean()
  defdelegate valid_meeting_url?(url), to: Urls

  # ---------------
  # OAuth URL generation
  # ---------------
  @spec oauth_authorization_url(pos_integer(), provider()) ::
          {:ok, String.t()} | {:error, String.t()}
  def oauth_authorization_url(user_id, provider) when is_integer(user_id) do
    provider = normalize_provider(provider)

    case provider do
      :google_meet ->
        google_oauth_authorization_url(user_id)

      :teams ->
        teams_oauth_authorization_url(user_id)

      _ ->
        {:error, "Provider does not support OAuth"}
    end
  end

  # ---------------
  # Helpers
  # ---------------
  defp normalize_provider(p) when is_atom(p), do: p

  defp normalize_provider(p) when is_binary(p) do
    case String.downcase(p) do
      "google_meet" -> :google_meet
      "teams" -> :teams
      "mirotalk" -> :mirotalk
      "custom" -> :custom
      "none" -> :none
      _other -> :unknown
    end
  end

  defp format_google_oauth_error(%RuntimeError{message: "Google State Secret not configured"}),
    do:
      "Google OAuth is not configured. Please set GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, and GOOGLE_STATE_SECRET environment variables."

  defp format_google_oauth_error(%RuntimeError{message: "Google Client ID not configured"}),
    do: "Google OAuth is not configured. Please set GOOGLE_CLIENT_ID environment variable."

  defp format_google_oauth_error(%RuntimeError{message: "Google Client Secret not configured"}),
    do: "Google OAuth is not configured. Please set GOOGLE_CLIENT_SECRET environment variable."

  defp format_google_oauth_error(error),
    do: "Failed to setup Google OAuth: #{Exception.message(error)}"

  defp format_outlook_oauth_error(%RuntimeError{message: "Outlook State Secret not configured"}),
    do:
      "Microsoft OAuth is not configured. Please set OUTLOOK_CLIENT_ID, OUTLOOK_CLIENT_SECRET, and OUTLOOK_STATE_SECRET environment variables."

  defp format_outlook_oauth_error(%RuntimeError{message: "Outlook Client ID not configured"}),
    do: "Microsoft OAuth is not configured. Please set OUTLOOK_CLIENT_ID environment variable."

  defp format_outlook_oauth_error(%RuntimeError{message: "Outlook Client Secret not configured"}),
    do:
      "Microsoft OAuth is not configured. Please set OUTLOOK_CLIENT_SECRET environment variable."

  defp format_outlook_oauth_error(error),
    do: "Failed to setup Microsoft OAuth: #{Exception.message(error)}"

  defp google_oauth_authorization_url(user_id) do
    redirect_uri = "#{Endpoint.url()}/auth/google/video/callback"
    url = GoogleOAuthHelper.authorization_url(user_id, redirect_uri, [:calendar])
    {:ok, url}
  rescue
    error -> {:error, format_google_oauth_error(error)}
  end

  defp teams_oauth_authorization_url(user_id) do
    redirect_uri = "#{Endpoint.url()}/auth/teams/video/callback"
    url = TeamsOAuthHelper.authorization_url(user_id, redirect_uri)
    {:ok, url}
  rescue
    error -> {:error, format_outlook_oauth_error(error)}
  end
end
