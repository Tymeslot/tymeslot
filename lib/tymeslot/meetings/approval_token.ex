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

  It also carries the `approval_requested_at` the meeting was stamped with
  when the token was issued, and is refused if that no longer matches the
  meeting's current value. A meeting re-enters the approval gate on certain
  reschedules (`Tymeslot.Bookings.Reschedule`), which stamps a fresh
  `approval_requested_at` for the new request — without this check, every
  token issued for an earlier request would still answer the new one, so a
  stale or forwarded email could decide a request its recipient never saw.

  ## Lifetime

  Tokens are valid for `max_age/0` — long enough to cover the longest approval
  window plus a generous margin for a host who reads their mail late, short
  enough that a forwarded email does not stay actionable indefinitely. There
  is no revocation list beyond the `approval_requested_at` check above:
  answering the request moves it out of `"awaiting_approval"`, and the
  guarded transition then refuses every later use of the token on its own.

  ## What the token does not do

  It does not authorise the action on its own. The endpoint it unlocks renders
  the request and takes Approve or Decline as an explicit submission, never as
  a side effect of loading the page — corporate mail scanners and link
  preview crawlers fetch every URL in an inbound message, and a GET that
  approved would hand them the host's calendar.
  """

  alias Phoenix.Token
  alias Tymeslot.Meetings.MeetingQueries
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

  @doc """
  Signs a token identifying one booking request and the host who owns it.

  Binds the token to `approval_requested_at` as it stands right now, so a
  later re-entry into the approval gate (which stamps a fresh value) leaves
  this token unable to verify.
  """
  @spec sign(Meeting.t()) :: String.t()
  def sign(%Meeting{id: id, organizer_user_id: organizer_user_id} = meeting) do
    Token.sign(Endpoint, @salt, {id, organizer_user_id, meeting.approval_requested_at})
  end

  @doc """
  Verifies a token, returning the meeting it was issued for.

  Refuses a token whose organiser no longer matches the meeting's current
  one, and a token whose `approval_requested_at` no longer matches the
  meeting's current one, so a token from a previous request cannot answer a
  new one issued after a re-entry into the approval gate.

  Says nothing about whether the request is still answerable; that is the
  caller's next question and `Tymeslot.Meetings.Approval` is where it is
  settled.
  """
  @spec verify(String.t()) :: {:ok, Meeting.t()} | {:error, atom()}
  def verify(token) when is_binary(token) do
    SignedToken.verify(token, @salt, @max_age_seconds, &validate/1)
  end

  def verify(_token), do: {:error, :invalid}

  defp validate({meeting_id, organizer_user_id, requested_at})
       when is_binary(meeting_id) and is_integer(organizer_user_id) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, %{organizer_user_id: ^organizer_user_id} = meeting} ->
        if same_request?(meeting.approval_requested_at, requested_at) do
          {:ok, meeting}
        else
          {:error, :stale}
        end

      {:ok, _meeting} ->
        {:error, :organizer_mismatch}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp validate(_payload), do: {:error, :invalid}

  defp same_request?(nil, nil), do: true

  defp same_request?(%DateTime{} = current, %DateTime{} = issued),
    do: DateTime.compare(current, issued) == :eq

  defp same_request?(_current, _issued), do: false
end
