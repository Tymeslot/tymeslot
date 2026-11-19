defmodule Tymeslot.Meetings.EmailVerificationToken do
  @moduledoc """
  Signed tokens carried by the link in the verification email.

  The token binds the meeting's id and the `verification_deadline_at` it was
  issued with. A token whose deadline no longer matches the stored one is
  refused as stale, so a link cannot outlive a booking that was re-stamped.

  It deliberately does not contain the meeting `uid`: a `Phoenix.Token` is
  signed, not encrypted, and the `uid` opens the public cancel and reschedule
  pages, which must not be reachable before the address is verified.

  The token's own lifetime (two days, see `Tymeslot.SignedToken`) is longer
  than the 30-minute hold, so a late click reads "expired" rather than
  "invalid". Whether the hold itself has lapsed is the domain's question
  (`Tymeslot.Meetings.EmailVerification`), not the token's.
  """

  alias Tymeslot.Auth
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.SignedToken

  @doc "Signs a token for one held booking, bound to its current deadline."
  @spec sign(Meeting.t()) :: String.t()
  def sign(%Meeting{id: id, verification_deadline_at: %DateTime{} = deadline}) do
    SignedToken.sign(:booking_email_verification, {id, DateTime.to_unix(deadline)})
  end

  @doc """
  Verifies a token and returns the meeting it was issued for.

  Refuses with `{:error, :not_found}` when the meeting is gone or its
  organiser's account is pending deletion, and with `{:error, :stale}` when the
  stored deadline differs from the token's.
  """
  @spec verify(String.t()) ::
          {:ok, Meeting.t()} | {:error, :invalid | :expired | :missing | :stale | :not_found}
  def verify(token) when is_binary(token) do
    SignedToken.verify(:booking_email_verification, token, validate: &validate/1)
  end

  def verify(_token), do: {:error, :invalid}

  defp validate({meeting_id, deadline_unix})
       when is_binary(meeting_id) and is_integer(deadline_unix) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} -> check_binding(meeting, deadline_unix)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp validate(_payload), do: {:error, :invalid}

  defp check_binding(meeting, deadline_unix) do
    cond do
      Auth.deletion_pending?(meeting.organizer_user_id) -> {:error, :not_found}
      deadline_unix(meeting) != deadline_unix -> {:error, :stale}
      true -> {:ok, meeting}
    end
  end

  defp deadline_unix(%{verification_deadline_at: %DateTime{} = deadline}),
    do: DateTime.to_unix(deadline)

  defp deadline_unix(_meeting), do: nil
end
