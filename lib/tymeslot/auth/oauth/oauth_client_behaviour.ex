defmodule Tymeslot.Auth.OAuth.OAuthClientBehaviour do
  @moduledoc """
  A behaviour module defining the functions needed from OAuth2.Client for testing.
  """

  @callback get_token(any(), keyword()) :: {:ok, map()} | {:error, any()}
  @callback get(any(), String.t()) :: {:ok, map()} | {:error, any()}
end
