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

  @doc """
  Returns the Zoom Client ID from configuration or environment variables.
  """
  @spec client_id() :: String.t() | nil
  def client_id do
    Application.get_env(:tymeslot, :zoom_oauth)[:client_id] || System.get_env("ZOOM_CLIENT_ID")
  end

  @doc """
  Returns the Zoom Client Secret from configuration or environment variables.
  """
  @spec client_secret() :: String.t() | nil
  def client_secret do
    Application.get_env(:tymeslot, :zoom_oauth)[:client_secret] ||
      System.get_env("ZOOM_CLIENT_SECRET")
  end

  @doc """
  Returns the state secret used for OAuth CSRF protection.
  """
  @spec state_secret() :: String.t()
  def state_secret do
    Application.get_env(:tymeslot, :zoom_oauth)[:state_secret] ||
      System.get_env("ZOOM_STATE_SECRET") ||
      raise "Zoom OAuth State Secret not configured"
  end

  @doc """
  Fetches client_id and returns it in a tagged tuple or error.
  """
  @spec fetch_client_id() :: {:ok, String.t()} | {:error, String.t()}
  def fetch_client_id do
    case client_id() do
      id when is_binary(id) and byte_size(id) > 0 -> {:ok, id}
      _other -> {:error, "Zoom Client ID not configured"}
    end
  end

  @doc """
  Fetches client_secret and returns it in a tagged tuple or error.
  """
  @spec fetch_client_secret() :: {:ok, String.t()} | {:error, String.t()}
  def fetch_client_secret do
    case client_secret() do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _other -> {:error, "Zoom Client Secret not configured"}
    end
  end

  @doc """
  Returns the Secret Token used to sign Zoom webhook requests
  (deauthorization events).
  """
  @spec deauth_secret() :: String.t() | nil
  def deauth_secret do
    Application.get_env(:tymeslot, :zoom_oauth)[:deauth_secret] ||
      System.get_env("ZOOM_DEAUTH_SECRET")
  end

  @doc """
  Fetches the deauth secret and returns it in a tagged tuple or error.
  """
  @spec fetch_deauth_secret() :: {:ok, String.t()} | {:error, :missing_deauth_secret}
  def fetch_deauth_secret do
    case deauth_secret() do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _other -> {:error, :missing_deauth_secret}
    end
  end
end
