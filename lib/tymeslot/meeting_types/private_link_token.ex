defmodule Tymeslot.MeetingTypes.PrivateLinkToken do
  @moduledoc """
  Signed tokens for private meeting-type booking links.

  Encodes `{user_id, meeting_type_id, expires_at}` into a self-contained URL token.
  No database storage is required — the token carries its own expiry.

  ## Usage

      # Generate a permanent link
      token = PrivateLinkToken.sign(user_id, meeting_type_id)

      # Generate a link valid for 30 days
      token = PrivateLinkToken.sign(user_id, meeting_type_id, 30)

      # Verify
      {:ok, {user_id, meeting_type_id}} = PrivateLinkToken.verify(token)
      {:error, :expired}               = PrivateLinkToken.verify(expired_token)
  """

  alias Phoenix.Token
  alias Tymeslot.SignedToken

  @salt "private_booking_link_v1"

  @doc """
  Signs a private booking token for the given user and meeting type.

  Pass `valid_days` to create a time-limited link.
  Omit (or pass `nil`) for a permanent link.
  """
  @spec sign(integer(), integer(), pos_integer() | nil) :: String.t()
  def sign(user_id, meeting_type_id, valid_days \\ nil)
      when is_integer(user_id) and is_integer(meeting_type_id) do
    expires_at =
      if is_integer(valid_days) and valid_days > 0,
        do: System.os_time(:second) + valid_days * 86_400,
        else: nil

    Token.sign(TymeslotWeb.Endpoint, @salt, {user_id, meeting_type_id, expires_at})
  end

  @doc """
  Verifies a private booking token.

  Returns `{:ok, {user_id, meeting_type_id}}` on success.
  Returns `{:error, :expired}` if the token's validity window has passed.
  Returns `{:error, :invalid}` for malformed or tampered tokens.
  """
  @spec verify(String.t()) :: {:ok, {integer(), integer()}} | {:error, :expired | :invalid}
  def verify(token) do
    # We use :infinity for Phoenix.Token's own max_age — expiry is handled
    # inside validate/1 using the embedded expires_at timestamp.
    SignedToken.verify(token, @salt, :infinity, &validate/1)
  end

  # Permanent token (no expiry)
  defp validate({user_id, mt_id, nil})
       when is_integer(user_id) and is_integer(mt_id),
       do: {:ok, {user_id, mt_id}}

  # Time-limited token — check wall clock
  defp validate({user_id, mt_id, expires_at})
       when is_integer(user_id) and is_integer(mt_id) and is_integer(expires_at) do
    if System.os_time(:second) <= expires_at,
      do: {:ok, {user_id, mt_id}},
      else: {:error, :expired}
  end

  defp validate(_term), do: {:error, :invalid}
end
