defmodule Tymeslot.Infrastructure.VerificationBehaviour do
  @moduledoc """
  Behaviour definition for user verification operations.
  """

  @type verification_result ::
          {:ok, struct()} | {:error, atom()} | {:error, :rate_limited, String.t()}
  @type socket_or_conn :: Phoenix.LiveView.Socket.t() | Plug.Conn.t()

  @callback verify_user_email(socket_or_conn(), struct(), map()) ::
              verification_result()
  @callback verify_user(String.t() | integer()) :: verification_result()
  @callback verify_user_token(String.t()) :: {:ok, struct()} | {:error, atom()}
  @callback resend_verification_email(socket_or_conn(), struct()) :: verification_result()
end
