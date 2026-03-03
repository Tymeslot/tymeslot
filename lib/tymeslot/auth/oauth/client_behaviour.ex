defmodule Tymeslot.Auth.OAuth.ClientBehaviour do
  @moduledoc """
  Behaviour for OAuth Client to allow mocking in tests.
  """

  @type provider :: :github | :google | :oauth

  @callback build(provider, String.t(), String.t()) :: OAuth2.Client.t()
  @callback exchange_code_for_token(OAuth2.Client.t(), String.t()) ::
              {:ok, OAuth2.Client.t()} | {:error, any()}
  @callback get_user_info(OAuth2.Client.t(), provider) :: {:ok, map()} | {:error, any()}
end
