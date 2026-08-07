defmodule Tymeslot.Integrations.Video.Teams.TeamsOAuthHelperBehaviour do
  @moduledoc """
  Behaviour for Microsoft Teams OAuth helper to enable mocking in tests.
  """

  @callback authorization_url(term(), String.t()) :: String.t()
  # With options, used when reconnecting an existing integration to target the
  # account already connected via `integration_id` and `login_hint`.
  @callback authorization_url(term(), String.t(), keyword()) :: String.t()
  @callback exchange_code_for_tokens(String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, String.t()}
  @callback refresh_access_token(String.t(), String.t() | nil) ::
              {:ok, map()} | {:error, String.t()}
  @callback validate_token(map()) :: {:ok, :valid | :needs_refresh} | {:error, String.t()}
end
