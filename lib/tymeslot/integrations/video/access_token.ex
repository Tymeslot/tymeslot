defmodule Tymeslot.Integrations.Video.AccessToken do
  @moduledoc """
  Mints a usable OAuth access token for a stored video integration.

  Exists so that callers outside this domain — diagnostic tooling, chiefly —
  can talk to a provider's API without reaching for the integration's
  credentials themselves. Decryption stays with the schema that knows which
  fields are encrypted, and the refresh stays with the provider that knows how
  to take a lock and write the new credentials back.

  Reproducing either outside Core is worse than verbose. Decrypting elsewhere
  spreads knowledge `Tymeslot.Security.EncryptedStorage` expects to stay with
  the schema, and refreshing through a bare OAuth helper skips the lock that
  stops two callers spending the same refresh token, skips the write-back, and
  skips the injection point the test doubles rely on.
  """

  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @type reason :: :not_found | :unsupported_provider | term()

  @doc """
  Returns a currently-valid access token for the user's integration.

  Refreshes first if the stored token has expired, through the provider's own
  `c:Tymeslot.Integrations.Video.Providers.ProviderBehaviour.ensure_valid_token/1`,
  so the refreshed credentials are persisted for every other caller too.

  `{:error, :unsupported_provider}` means the provider holds no OAuth grant to
  mint a token from (a self-hosted MiroTalk, a custom URL), not that anything
  went wrong.
  """
  @spec fetch(integer(), integer()) :: {:ok, String.t()} | {:error, reason()}
  def fetch(integration_id, user_id) do
    with {:ok, integration} <- VideoIntegrationQueries.get_for_user(integration_id, user_id),
         {:ok, module} <- token_provider(integration.provider),
         {:ok, config} <- refresh(module, integration) do
      token(config)
    end
  end

  defp token_provider(provider) do
    case ProviderConfig.parse_known(provider) do
      {:ok, provider_type} ->
        provider_type |> ProviderConfig.get_provider_module() |> token_module()

      {:error, :unknown} ->
        {:error, :unsupported_provider}
    end
  end

  defp token_module(nil), do: {:error, :unsupported_provider}

  defp token_module(module) do
    if exports?(module, :ensure_valid_token, 1),
      do: {:ok, module},
      else: {:error, :unsupported_provider}
  end

  # `function_exported?/3` answers false for a module that has not been loaded
  # yet, which in a lazily-loading dev or test VM is most of them.
  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp refresh(module, integration) do
    decrypted = VideoIntegrationSchema.decrypt_credentials(integration)

    integration
    |> module.build_config(decrypted, [])
    |> module.ensure_valid_token()
  end

  defp token(%{access_token: access_token}) when is_binary(access_token) and access_token != "",
    do: {:ok, access_token}

  defp token(_config), do: {:error, :no_access_token}
end
