defmodule Tymeslot.Infrastructure.Config do
  @moduledoc """
  Configuration module for the Tymeslot application.
  Provides centralized access to configuration values to reduce duplication
  and ensure consistency across the codebase.
  """

  # Database Modules

  @doc """
  Gets the user queries module configured for the application.
  """
  @spec user_queries_module() :: module()
  def user_queries_module do
    get_module(:user_queries_module, Tymeslot.Auth.UserQueries)
  end

  @doc """
  Gets the user token queries module configured for the application.
  """
  @spec user_token_queries_module() :: module()
  def user_token_queries_module do
    get_module(:user_token_queries_module, Tymeslot.Auth.UserTokenQueries)
  end

  @doc """
  Gets the user schema module configured for the application.
  """
  @spec user_schema_module() :: module()
  def user_schema_module do
    get_module(:user_schema_module, Tymeslot.Auth.UserSchema)
  end

  @doc """
  Gets the user session queries module configured for the application.
  """
  @spec user_session_queries_module() :: module()
  def user_session_queries_module do
    get_module(:user_session_queries_module, Tymeslot.Auth.UserSessionQueries)
  end

  # Authentication Modules

  # Service Modules

  @doc """
  Gets the email service module configured for the application.
  """
  @spec email_service_module() :: module()
  def email_service_module do
    get_module(:email_service_module, Tymeslot.Emails.EmailService)
  end

  @doc """
  Gets the OAuth helper module configured for the application.
  """
  @spec oauth_helper_module() :: module()
  def oauth_helper_module do
    get_module(:oauth_helper_module, Tymeslot.Auth.OAuth.Helper)
  end

  @doc """
  Gets the HTTP client module configured for the application.

  Read at runtime so tests can inject a mock via `with_config/3` or
  `Application.put_env/3`.
  """
  @spec http_client_module() :: module()
  def http_client_module do
    get_module(:http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end

  @doc """
  Gets the Google Calendar API module configured for the application.
  """
  @spec google_calendar_api_module() :: module()
  def google_calendar_api_module do
    get_module(:google_calendar_api_module, Tymeslot.Integrations.Calendar.Google.CalendarAPI)
  end

  @doc """
  Gets the Outlook Calendar API module configured for the application.
  """
  @spec outlook_calendar_api_module() :: module()
  def outlook_calendar_api_module do
    get_module(:outlook_calendar_api_module, Tymeslot.Integrations.Calendar.Outlook.CalendarAPI)
  end

  # Configuration Modules

  @doc """
  Gets the app configuration module configured for the application.
  """
  @spec app_config_module() :: module()
  def app_config_module do
    module = get_module(:app_config_module, Tymeslot.Infrastructure.AppConfig)

    if Code.ensure_loaded?(module) do
      module
    else
      Tymeslot.Infrastructure.AppConfig
    end
  end

  # Configuration Values

  @doc """
  Gets the success redirect path after authentication.
  """
  @spec success_redirect_path() :: String.t()
  def success_redirect_path do
    get_auth_config(:success_redirect_path, "/dashboard")
  end

  @doc """
  Gets the login path.
  """
  @spec login_path() :: String.t()
  def login_path do
    get_auth_config(:login_path, "/auth/login")
  end

  # Provider settings (single source of truth)
  @doc """
  Returns the calendar providers configuration map.
  This should be used as the source of truth for which calendar providers are enabled.
  """
  @spec calendar_provider_settings() :: map()
  def calendar_provider_settings do
    Application.get_env(:tymeslot, :calendar_providers, %{})
  end

  @doc """
  Returns the video providers configuration map.
  This should be used as the source of truth for which video providers are enabled.
  """
  @spec video_provider_settings() :: map()
  def video_provider_settings do
    Application.get_env(:tymeslot, :video_providers, %{})
  end

  @doc """
  Returns the configured environment tag (e.g., :dev, :test, :prod).
  """
  @spec environment() :: atom() | nil
  def environment do
    Application.get_env(:tymeslot, :environment)
  end

  @doc """
  Checks if new user registration is enabled.
  """
  @spec registration_enabled?() :: boolean()
  def registration_enabled? do
    app_config_module().registration_enabled?()
  end

  @doc """
  Checks if password-based authentication is enabled.
  When disabled, only OAuth login flows are available.
  """
  @spec password_auth_enabled?() :: boolean()
  def password_auth_enabled? do
    app_config_module().password_auth_enabled?()
  end

  @doc """
  Returns true if at least one social auth provider (Google, GitHub, or the
  generic OAuth/OIDC adapter) is enabled. Used to determine whether disabling
  password auth is safe — without an alternative log-in path it would lock
  every user out.
  """
  @spec any_social_auth_enabled?() :: boolean()
  def any_social_auth_enabled? do
    social_auth = Application.get_env(:tymeslot, :social_auth, [])

    Keyword.get(social_auth, :google_enabled, false) or
      Keyword.get(social_auth, :github_enabled, false) or
      Keyword.get(social_auth, :oauth_enabled, false)
  end

  @doc """
  Checks if legal agreements should be enforced.
  """
  @spec enforce_legal_agreements?() :: boolean()
  def enforce_legal_agreements? do
    app_config_module().enforce_legal_agreements?()
  end

  @doc """
  Checks if marketing-related links should be shown.
  """
  @spec show_marketing_links?() :: boolean()
  def show_marketing_links? do
    app_config_module().show_marketing_links?()
  end

  @doc """
  Checks if the logo should link to the marketing site.
  """
  @spec logo_links_to_marketing?() :: boolean()
  def logo_links_to_marketing? do
    app_config_module().logo_links_to_marketing?()
  end

  @doc """
  Gets the site home path.
  """
  @spec site_home_path() :: String.t()
  def site_home_path do
    app_config_module().site_home_path()
  end

  # Private Helpers

  defp get_module(key, default) do
    Application.get_env(:tymeslot, key, default)
  end

  defp get_auth_config(key, default) do
    case Application.get_env(:tymeslot, :auth) do
      nil -> default
      config when is_list(config) -> Keyword.get(config, key, default)
      _non_list -> default
    end
  end
end
