defmodule Tymeslot.Integrations.Shared.OAuth.GoogleTokenRevocation do
  @moduledoc """
  Revokes a Google OAuth grant, as used when an account is deleted.

  Revoking either token of a grant ends the whole grant, refresh token
  included, so the refresh token is the better one to send: it is still
  valid after the access token has expired. Google answers `400` for a token
  it no longer knows (already revoked, or the user removed the app), which
  leaves nothing to revoke and so counts as done.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Shared.GoogleConfig

  @timeout_ms 10_000

  @spec revoke(String.t() | nil) :: :ok | {:error, term()}
  def revoke(token) when is_binary(token) and token != "" do
    body = URI.encode_query(%{"token" => token})
    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Config.http_client_module().post(GoogleConfig.revoke_url(), body, headers,
           receive_timeout: @timeout_ms
         ) do
      {:ok, %{status: status}} when status in [200, 400] -> :ok
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke(_no_token), do: {:error, :no_token}

  @doc """
  Revokes the grant an integration holds, by its refresh token or, failing
  that, its access token. An integration with neither holds no grant, so
  there is nothing to revoke and it counts as done.
  """
  @spec revoke_grant(%{
          :refresh_token => String.t() | nil,
          :access_token => String.t() | nil,
          optional(atom()) => term()
        }) :: :ok | {:error, term()}
  def revoke_grant(%{refresh_token: refresh_token, access_token: access_token}) do
    case Enum.find([refresh_token, access_token], &(is_binary(&1) and &1 != "")) do
      nil -> :ok
      token -> revoke(token)
    end
  end
end
