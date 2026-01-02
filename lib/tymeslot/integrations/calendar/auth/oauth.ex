defmodule Tymeslot.Integrations.Calendar.OAuth do
  @moduledoc """
  OAuth helper functions for calendar providers (Google, Outlook).
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Google.OAuthHelper, as: GoogleOAuthHelper
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper, as: OutlookOAuthHelper
  alias TymeslotWeb.Endpoint

  @type user_id :: pos_integer()

  @doc """
  Initiate Google Calendar OAuth flow and return authorization URL.
  """
  @spec initiate_google_oauth(user_id()) :: {:ok, String.t()} | {:error, String.t()}
  def initiate_google_oauth(user_id) when is_integer(user_id) do
    redirect_uri = "#{Endpoint.url()}/auth/google/calendar/callback"

    authorization_url = google_oauth_helper().authorization_url(user_id, redirect_uri)
    {:ok, authorization_url}
  rescue
    error -> {:error, format_oauth_error(error, "Google")}
  end

  @doc """
  Initiate Outlook Calendar OAuth flow and return authorization URL.
  """
  @spec initiate_outlook_oauth(user_id()) :: {:ok, String.t()} | {:error, String.t()}
  def initiate_outlook_oauth(user_id) when is_integer(user_id) do
    redirect_uri = "#{Endpoint.url()}/auth/outlook/calendar/callback"

    authorization_url = outlook_oauth_helper().authorization_url(user_id, redirect_uri)
    {:ok, authorization_url}
  rescue
    error -> {:error, format_oauth_error(error, "Outlook")}
  end

  @doc """
  Initiate a Google scope upgrade for an existing integration.
  Returns {:ok, url} or {:error, reason}.
  """
  @spec initiate_google_scope_upgrade(user_id(), pos_integer()) ::
          {:ok, String.t()} | {:error, any()}
  def initiate_google_scope_upgrade(user_id, integration_id)
      when is_integer(user_id) and is_integer(integration_id) do
    with {:ok, integration} <- Calendar.get_integration(integration_id, user_id),
         true <- integration.provider == "google",
         {:ok, url} <- initiate_google_oauth(user_id) do
      {:ok, url}
    else
      false -> {:error, :invalid_provider}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a Google integration needs scope upgrade.
  """
  @spec needs_scope_upgrade?(map()) :: boolean()
  def needs_scope_upgrade?(integration) do
    integration.provider == "google" && GoogleProvider.needs_scope_upgrade?(integration)
  end

  @doc """
  Format OAuth-related errors into user-friendly strings.
  """
  @spec format_oauth_error(any(), String.t()) :: String.t()
  def format_oauth_error(error, provider) do
    case error do
      %RuntimeError{message: message} -> format_runtime_error_message(message, provider)
      _ -> "Failed to setup #{provider} OAuth: #{Exception.message(error)}"
    end
  end

  defp format_runtime_error_message(message, provider) do
    error_type =
      cond do
        String.contains?(message, "State Secret not configured") -> :state_secret
        String.contains?(message, "Client ID not configured") -> :client_id
        String.contains?(message, "Client Secret not configured") -> :client_secret
        true -> :generic
      end

    format_oauth_config_message(error_type, provider, message)
  end

  defp format_oauth_config_message(:state_secret, provider, _message) do
    "#{provider} OAuth is not configured. Please set #{String.upcase(provider)}_CLIENT_ID, #{String.upcase(provider)}_CLIENT_SECRET, and #{String.upcase(provider)}_STATE_SECRET environment variables."
  end

  defp format_oauth_config_message(:client_id, provider, _message) do
    "#{provider} OAuth is not configured. Please set #{String.upcase(provider)}_CLIENT_ID environment variable."
  end

  defp format_oauth_config_message(:client_secret, provider, _message) do
    "#{provider} OAuth is not configured. Please set #{String.upcase(provider)}_CLIENT_SECRET environment variable."
  end

  defp format_oauth_config_message(:generic, provider, message) do
    "Failed to setup #{provider} OAuth: #{message}"
  end

  defp google_oauth_helper do
    Application.get_env(:tymeslot, :google_calendar_oauth_helper, GoogleOAuthHelper)
  end

  defp outlook_oauth_helper do
    Application.get_env(:tymeslot, :outlook_calendar_oauth_helper, OutlookOAuthHelper)
  end
end
