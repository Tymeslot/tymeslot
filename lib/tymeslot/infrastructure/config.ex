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
    get_module(:user_queries_module, Tymeslot.DatabaseQueries.UserQueries)
  end

  @doc """
  Gets the user schema module configured for the application.
  """
  @spec user_schema_module() :: module()
  def user_schema_module do
    get_module(:user_schema_module, Tymeslot.DatabaseSchemas.UserSchema)
  end

  @doc """
  Gets the user session queries module configured for the application.
  """
  @spec user_session_queries_module() :: module()
  def user_session_queries_module do
    get_module(:user_session_queries_module, Tymeslot.DatabaseQueries.UserSessionQueries)
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

  # Configuration Values

  @doc """
  Gets the application name.
  """
  @spec app_name() :: String.t()
  def app_name do
    if function_exported?(Tymeslot, :get_app_name, 0) do
      Tymeslot.get_app_name()
    else
      "Tymeslot"
    end
  end

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

  # Private Helpers

  defp get_module(key, default) do
    Application.get_env(:tymeslot, key, default)
  end

  defp get_auth_config(key, default) do
    case Application.get_env(:tymeslot, :auth) do
      nil -> default
      config when is_list(config) -> Keyword.get(config, key, default)
      _ -> default
    end
  end
end
