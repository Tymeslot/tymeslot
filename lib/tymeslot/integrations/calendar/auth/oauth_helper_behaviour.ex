defmodule Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour do
  @moduledoc """
  Behaviour for Calendar OAuth helpers to enable mocking in tests.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @callback authorization_url(pos_integer(), String.t()) :: String.t()
  @callback authorization_url(pos_integer(), String.t(), list(atom() | String.t()) | keyword()) ::
              String.t()
  @type callback_error :: :calendar_scope_missing | String.t()

  @callback handle_callback(String.t(), String.t(), String.t()) ::
              {:ok, CalendarIntegrationSchema.t()} | {:error, callback_error()}
  @callback exchange_code_for_tokens(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback refresh_access_token(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
end
