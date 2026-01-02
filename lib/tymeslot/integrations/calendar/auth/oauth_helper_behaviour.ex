defmodule Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour do
  @moduledoc """
  Behaviour for Calendar OAuth helpers to enable mocking in tests.
  """

  @callback authorization_url(pos_integer(), String.t()) :: String.t()
  @callback handle_callback(String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, String.t()}
  @callback exchange_code_for_tokens(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
end
