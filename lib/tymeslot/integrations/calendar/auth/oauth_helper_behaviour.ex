defmodule Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour do
  @moduledoc """
  Behaviour for Calendar OAuth helpers to enable mocking in tests.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Shared.OAuth.State

  @callback authorization_url(pos_integer(), String.t()) :: String.t()
  @callback authorization_url(pos_integer(), String.t(), list(atom() | String.t()) | keyword()) ::
              String.t()
  # Scopes and options together, used when reconnecting an existing
  # integration: the scopes are fixed by the caller while `integration_id` and
  # `login_hint` target the account already connected.
  @callback authorization_url(
              pos_integer(),
              String.t(),
              list(atom() | String.t()),
              keyword()
            ) :: String.t()

  # Optional because only the Google helper needs it: Outlook implements this
  # behaviour too but its authorisation URL takes no caller-supplied scopes.
  # The same goes for `refresh_access_token`, which only Google Meet's refresh
  # calls (through the Google helper); the Outlook calendar refresh runs in
  # `OutlookCalendarAPI.refresh_token/1`.
  @optional_callbacks authorization_url: 4, refresh_access_token: 2, refresh_access_token: 3
  @type callback_error :: :calendar_scope_missing | :duplicate_account | :not_found | String.t()

  # The code, the redirect URI, and the callback's state, already verified as
  # issued to the user completing it, with its flow's `:code_verifier`.
  @callback handle_callback(String.t(), String.t(), State.validated()) ::
              {:ok, CalendarIntegrationSchema.t()} | {:error, callback_error()}
  @callback exchange_code_for_tokens(String.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback refresh_access_token(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  # With options, used to carry a `:log_context` naming the integration behind
  # a refresh failure.
  @callback refresh_access_token(String.t(), String.t() | nil, keyword()) ::
              {:ok, map()} | {:error, term()}
end
