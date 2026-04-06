defmodule Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour do
  @moduledoc """
  Behaviour for Calendar OAuth helpers to enable mocking in tests.
  """

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema

  @callback authorization_url(pos_integer(), String.t()) :: String.t()
  @callback authorization_url(pos_integer(), String.t(), list(atom() | String.t())) :: String.t()
  @callback handle_callback(String.t(), String.t(), String.t()) ::
              {:ok, CalendarIntegrationSchema.t()} | {:error, String.t()}
  @callback exchange_code_for_tokens(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback refresh_access_token(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
end
