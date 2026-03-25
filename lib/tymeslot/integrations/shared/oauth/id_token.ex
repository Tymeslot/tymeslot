defmodule Tymeslot.Integrations.Common.OAuth.IdToken do
  @moduledoc """
  Decodes id_token JWTs from OAuth providers to extract account identity claims.

  ## Security Note

  No signature verification is performed. This is safe per OIDC spec Section 3.1.3.7
  because these tokens are received directly from the provider's token endpoint over
  TLS in the Authorization Code flow. If the architecture ever changes to receive
  id_tokens via front-channel (implicit flow), signature verification becomes mandatory.
  """

  @type claims :: %{
          sub: String.t() | nil,
          oid: String.t() | nil,
          email: String.t() | nil,
          preferred_username: String.t() | nil,
          tid: String.t() | nil
        }

  @doc """
  Decodes an id_token JWT and extracts identity claims.

  Returns `{:ok, claims}` with a map of extracted claims, or `{:error, :invalid_token}`.
  """
  @spec decode(String.t() | nil) :: {:ok, claims()} | {:error, :invalid_token}
  def decode(nil), do: {:error, :invalid_token}

  def decode(token) when is_binary(token) do
    with [_header, payload_b64, _signature] <- String.split(token, "."),
         {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, payload} <- Jason.decode(payload_json) do
      {:ok,
       %{
         sub: payload["sub"],
         oid: payload["oid"],
         email: payload["email"] || payload["preferred_username"],
         preferred_username: payload["preferred_username"],
         tid: payload["tid"]
       }}
    else
      _error -> {:error, :invalid_token}
    end
  end

  def decode(_other), do: {:error, :invalid_token}
end
