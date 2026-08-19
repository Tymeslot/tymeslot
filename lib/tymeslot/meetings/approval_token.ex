defmodule Tymeslot.Meetings.ApprovalToken do
  @moduledoc """
  Signed tokens letting a host answer a booking request from their email.

  Cancel and reschedule links elsewhere in Tymeslot are unguessable meeting
  UIDs scoped to the profile owner. That is proportionate for an invitee
  acting on their own booking, but not for an action that commits the host's
  calendar, so approval links are signed with `Phoenix.Token` and carry the
  organiser they were issued for. A token that does not match the meeting's
  current organiser is refused, so a link cannot be replayed against a booking
  that has since moved accounts.

  ## Lifetime

  Tokens are valid for `max_age/0` — long enough to cover the longest approval
  window plus a generous margin for a host who reads their mail late, short
  enough that a forwarded email does not stay actionable indefinitely. There
  is no revocation list and none is needed: answering the request moves it out
  of `"awaiting_approval"`, and the guarded transition then refuses every
  later use of the token on its own.

  ## What the token does not do

  It does not authorise the action on its own. The endpoint it unlocks renders
  the request and takes Approve or Decline as an explicit submission, never as
  a side effect of loading the page — corporate mail scanners and link
  preview crawlers fetch every URL in an inbound message, and a GET that
  approved would hand them the host's calendar.
  """

  alias Phoenix.Token
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.SignedToken
  alias TymeslotWeb.Endpoint

  @salt "meeting approval"

  # Two weeks is the longest window a meeting type may configure; the extra
  # fortnight covers a host coming back from leave to a request that has long
  # since lapsed, so they see "this expired" rather than a broken link.
  @max_age_seconds 28 * 24 * 3600

  @doc "How long an issued token stays verifiable, in seconds."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age_seconds

  @doc "Signs a token identifying one booking request and the host who owns it."
  @spec sign(Meeting.t()) :: String.t()
  def sign(%Meeting{id: id, organizer_user_id: organizer_user_id}) do
    Token.sign(Endpoint, @salt, {id, organizer_user_id})
  end

  @doc """
  Verifies a token, returning the meeting and organiser ids it was issued for.

  Says nothing about whether the request is still answerable; that is the
  caller's next question and `Tymeslot.Meetings.Approval` is where it is
  settled.
  """
  @spec verify(String.t()) :: {:ok, {String.t(), integer()}} | {:error, atom()}
  def verify(token) when is_binary(token) do
    SignedToken.verify(token, @salt, @max_age_seconds, &validate/1)
  end

  def verify(_token), do: {:error, :invalid}

  defp validate({meeting_id, organizer_user_id})
       when is_binary(meeting_id) and is_integer(organizer_user_id),
       do: {:ok, {meeting_id, organizer_user_id}}

  defp validate(_payload), do: {:error, :invalid}
end
