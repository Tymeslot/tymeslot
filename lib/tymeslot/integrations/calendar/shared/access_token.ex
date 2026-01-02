defmodule Tymeslot.Integrations.Calendar.Shared.AccessToken do
  @moduledoc """
  Helper utilities for ensuring calendar integrations have a valid access token
  before executing API calls.
  """

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Common.OAuth.Token, as: OAuthToken

  @default_buffer 300

  @spec with_access_token(
          CalendarIntegrationSchema.t(),
          (CalendarIntegrationSchema.t() ->
             {:ok, {String.t(), String.t(), DateTime.t()}} | any()),
          (String.t() -> any()),
          keyword()
        ) :: any()
  def with_access_token(integration, refresh_fun, callback, opts \\ []) do
    buffer_seconds = Keyword.get(opts, :buffer_seconds, @default_buffer)

    with {:ok, token} <-
           OAuthToken.ensure_valid_access_token(integration,
             decrypt_fun: &CalendarIntegrationSchema.decrypt_oauth_tokens/1,
             refresh_fun: refresh_fun,
             buffer_seconds: buffer_seconds
           ) do
      callback.(token)
    end
  end
end
