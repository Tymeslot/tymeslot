defmodule Tymeslot.Infrastructure.TokenBehaviour do
  @moduledoc """
  Behaviour for token-related operations used in Auth.
  """
  @callback generate_session_token(integer()) :: {String.t(), DateTime.t()}
  @callback generate_email_verification_token(integer()) :: {String.t(), DateTime.t(), String.t()}
  @callback generate_password_reset_token() :: {String.t(), DateTime.t()}
  @callback verify_token(String.t(), DateTime.t()) :: {:ok, String.t()} | {:error, :token_expired}
end
