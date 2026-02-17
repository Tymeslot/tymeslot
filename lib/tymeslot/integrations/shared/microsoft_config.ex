defmodule Tymeslot.Integrations.Shared.MicrosoftConfig do
  @moduledoc """
  Shared configuration helper for Microsoft Graph API integrations (Outlook and Teams).
  """

  @doc """
  Returns the Microsoft Client ID from configuration or environment variables.
  """
  @spec client_id() :: String.t() | nil
  def client_id do
    Application.get_env(:tymeslot, :outlook_oauth)[:client_id] ||
      System.get_env("OUTLOOK_CLIENT_ID")
  end

  @doc """
  Returns the Microsoft Client Secret from configuration or environment variables.
  """
  @spec client_secret() :: String.t() | nil
  def client_secret do
    Application.get_env(:tymeslot, :outlook_oauth)[:client_secret] ||
      System.get_env("OUTLOOK_CLIENT_SECRET")
  end

  @doc """
  Returns the state secret used for OAuth CSRF protection.
  """
  @spec state_secret() :: String.t() | nil
  def state_secret do
    Application.get_env(:tymeslot, :outlook_oauth)[:state_secret] ||
      System.get_env("OUTLOOK_STATE_SECRET")
  end

  @doc """
  Fetches client_id and returns it in a tagged tuple or error.
  """
  @spec fetch_client_id() :: {:ok, String.t()} | {:error, String.t()}
  def fetch_client_id do
    case client_id() do
      id when is_binary(id) and byte_size(id) > 0 -> {:ok, id}
      _other -> {:error, "Microsoft Client ID not configured"}
    end
  end

  @doc """
  Fetches client_secret and returns it in a tagged tuple or error.
  """
  @spec fetch_client_secret() :: {:ok, String.t()} | {:error, String.t()}
  def fetch_client_secret do
    case client_secret() do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _other -> {:error, "Microsoft Client Secret not configured"}
    end
  end

  @doc """
  The static Tenant ID used by Microsoft to identify all personal/consumer accounts.
  """
  @spec consumer_tenant_id() :: String.t()
  def consumer_tenant_id, do: "9188040d-6c67-4c5b-b112-36a304b66dad"
end
