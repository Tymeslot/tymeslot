defmodule Tymeslot.Auth.OAuth.Client do
  @moduledoc """
  OAuth2 client construction, token exchange, and authenticated requests.
  Also contains provider configuration and header handling.
  """

  @behaviour Tymeslot.Auth.OAuth.ClientBehaviour

  alias OAuth2.Client

  @type provider :: :github | :google | :oauth

  @doc """
  Build an OAuth2 client for a provider with redirect_uri and state.
  """
  @spec build(provider, String.t(), String.t()) :: Client.t()
  def build(:github, redirect_uri, state) do
    config = github_oauth_config()

    Client.new(
      strategy: OAuth2.Strategy.AuthCode,
      client_id: config.client_id,
      client_secret: config.client_secret,
      redirect_uri: redirect_uri,
      site: config.site,
      authorize_url: config.authorize_url,
      token_url: config.token_url,
      headers: [{"User-Agent", app_user_agent()}],
      params: %{"state" => state}
    )
  end

  def build(:google, redirect_uri, state) do
    config = google_oauth_config()

    Client.new(
      strategy: OAuth2.Strategy.AuthCode,
      client_id: config.client_id,
      client_secret: config.client_secret,
      redirect_uri: redirect_uri,
      site: config.site,
      authorize_url: config.authorize_url,
      token_url: config.token_url,
      headers: [{"User-Agent", app_user_agent()}],
      params: %{"state" => state}
    )
  end

  def build(:oauth, redirect_uri, state) do
    config = generic_oauth_config()

    Client.new(
      strategy: OAuth2.Strategy.AuthCode,
      client_id: config.client_id,
      client_secret: config.client_secret,
      redirect_uri: redirect_uri,
      site: config.site,
      authorize_url: config.authorize_url,
      token_url: config.token_url,
      headers: [{"User-Agent", app_user_agent()}],
      params: %{"state" => state}
    )
  end

  @doc """
  Exchange auth code for token.
  """
  @spec exchange_code_for_token(Client.t(), String.t()) :: {:ok, Client.t()} | {:error, any()}
  def exchange_code_for_token(client, code) do
    Client.get_token(client, code: code)
  end

  @doc """
  Add Authorization header to client based on provider.
  """
  @spec with_auth_header(Client.t(), provider) :: Client.t()
  def with_auth_header(client, :github) do
    access_token = parse_access_token(client.token.access_token)

    %{
      client
      | headers: [{"User-Agent", app_user_agent()}, {"Authorization", "token #{access_token}"}]
    }
  end

  def with_auth_header(client, :google) do
    access_token = parse_access_token(client.token.access_token)

    %{
      client
      | headers: [{"User-Agent", app_user_agent()}, {"Authorization", "Bearer #{access_token}"}]
    }
  end

  def with_auth_header(client, :oauth) do
    access_token = parse_access_token(client.token.access_token)

    %{
      client
      | headers: [{"User-Agent", app_user_agent()}, {"Authorization", "Bearer #{access_token}"}]
    }
  end

  @doc """
  Fetches user information from the provider.
  """
  @spec get_user_info(Client.t(), provider) :: {:ok, map()} | {:error, any()}
  def get_user_info(client, provider) do
    client = with_auth_header(client, provider)
    url = user_info_url(provider)

    case Client.get(client, url) do
      {:ok, %OAuth2.Response{body: body}} -> decode_oauth_body(body)
      err -> err
    end
  end

  defp user_info_url(:github), do: "https://api.github.com/user"
  defp user_info_url(:google), do: "https://www.googleapis.com/oauth2/v1/userinfo"

  defp user_info_url(:oauth) do
    config = Application.get_env(:tymeslot, :oauth_provider, [])
    Keyword.fetch!(config, :userinfo_url)
  end

  defp decode_oauth_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_oauth_body(body) when is_map(body), do: {:ok, body}
  defp decode_oauth_body(other), do: {:error, {:unexpected_body, other}}

  @doc """
  Parse access token from JSON or return as-is.
  """
  @spec parse_access_token(String.t()) :: String.t()
  def parse_access_token(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"access_token" => token}} -> token
      _other -> json_string
    end
  end

  # Provider configuration

  defp github_oauth_config do
    %{
      client_id: System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
      site: "https://github.com",
      authorize_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token"
    }
  end

  defp google_oauth_config do
    %{
      client_id: System.get_env("GOOGLE_CLIENT_ID"),
      client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
      site: "https://accounts.google.com",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token"
    }
  end

  defp generic_oauth_config do
    config = Application.get_env(:tymeslot, :oauth_provider, [])

    %{
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.fetch!(config, :client_secret),
      site: Keyword.fetch!(config, :site),
      authorize_url: Keyword.fetch!(config, :authorize_url),
      token_url: Keyword.fetch!(config, :token_url)
    }
  end

  defp app_user_agent do
    # User agent for OAuth requests
    "Tymeslot-Scheduler"
  end
end
