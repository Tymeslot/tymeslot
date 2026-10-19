defmodule Tymeslot.Integrations.Shared.ZoomConfig do
  @moduledoc """
  Configuration helper for Zoom OAuth credentials.

  Reads `ZOOM_CLIENT_ID`, `ZOOM_CLIENT_SECRET`, `ZOOM_STATE_SECRET`, and
  `ZOOM_DEAUTH_SECRET` from environment variables. Self-hosters create a
  Zoom Marketplace app and configure these values for their deployment.

  `ZOOM_DEAUTH_SECRET` is the Secret Token configured under the Marketplace
  app's Features → Event Subscriptions page; Zoom signs deauthorization
  webhook requests with it.
  """

  alias Tymeslot.Integrations.Shared.OAuthConfig

  @doc """
  Returns the state secret used for OAuth CSRF protection; raises when it is
  not configured.
  """
  @spec state_secret() :: String.t()
  def state_secret, do: OAuthConfig.fetch!(:zoom, :state_secret)

  @doc "The client id; raises when it is not configured."
  @spec client_id!() :: String.t()
  def client_id!, do: OAuthConfig.fetch!(:zoom, :client_id)

  @doc """
  Fetches client_id and returns it in a tagged tuple or error.
  """
  @spec fetch_client_id() :: {:ok, String.t()} | {:error, String.t()}
  def fetch_client_id, do: OAuthConfig.fetch(:zoom, :client_id)

  @doc """
  Fetches client_secret and returns it in a tagged tuple or error.
  """
  @spec fetch_client_secret() :: {:ok, String.t()} | {:error, String.t()}
  def fetch_client_secret, do: OAuthConfig.fetch(:zoom, :client_secret)

  @doc """
  Fetches the deauth secret, the Secret Token Zoom signs deauthorization
  webhook requests with.
  """
  @spec fetch_deauth_secret() :: {:ok, String.t()} | {:error, :missing_deauth_secret}
  def fetch_deauth_secret do
    case OAuthConfig.get(:zoom, :deauth_secret) do
      nil -> {:error, :missing_deauth_secret}
      secret -> {:ok, secret}
    end
  end
end
