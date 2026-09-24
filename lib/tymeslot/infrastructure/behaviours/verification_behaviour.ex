defmodule Tymeslot.Infrastructure.VerificationBehaviour do
  @moduledoc """
  Behaviour definition for user verification operations.
  """

  @type verification_result ::
          {:ok, struct()} | {:error, atom()} | {:error, :rate_limited, String.t()}

  @callback send_verification_email(struct(), String.t() | nil) :: verification_result()
  @callback verify_user(String.t() | integer()) :: verification_result()
end
