defmodule Tymeslot.Integrations.Video.Providers.OAuthCredentials do
  @moduledoc """
  The credential shape shared by every video provider authenticated with a
  bearer access token and a refresh token.

  Zoom and Google Meet carried byte-identical copies of both functions; Teams
  genuinely differs, because it also threads a tenant and a Microsoft user id,
  and keeps its own. A provider whose credentials are exactly an OAuth pair
  should delegate here rather than restate the shape.
  """

  @doc """
  The config a provider's API calls read, built from the stored integration and
  its decrypted credentials.
  """
  @spec build_config(map(), map(), keyword()) :: map()
  def build_config(integration, decrypted, _opts) do
    %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token,
      token_expires_at: integration.token_expires_at,
      oauth_scope: integration.oauth_scope,
      integration_id: integration.id,
      user_id: integration.user_id
    }
  end

  @doc """
  Which credential fields exist and which encrypted column each is stored in.
  """
  @spec credential_spec() :: map()
  def credential_spec do
    %{
      required: [],
      credential_pairs: [
        {:access_token, :access_token_encrypted},
        {:refresh_token, :refresh_token_encrypted}
      ],
      url_fields: []
    }
  end
end
