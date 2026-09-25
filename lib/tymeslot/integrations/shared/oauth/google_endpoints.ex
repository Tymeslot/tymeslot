defmodule Tymeslot.Integrations.Google.Endpoints do
  @moduledoc """
  Google's OAuth 2.0 endpoints, in one place for Google sign-in and the Google
  Calendar and Meet integrations.
  """

  @doc "The authorisation endpoint the browser is sent to."
  @spec authorize_url() :: String.t()
  def authorize_url, do: "https://accounts.google.com/o/oauth2/v2/auth"

  @doc "The token endpoint for code exchange and refresh."
  @spec token_url() :: String.t()
  def token_url, do: "https://oauth2.googleapis.com/token"

  @doc "The v1 userinfo endpoint; its response carries `verified_email`."
  @spec userinfo_url() :: String.t()
  def userinfo_url, do: "https://www.googleapis.com/oauth2/v1/userinfo"
end
