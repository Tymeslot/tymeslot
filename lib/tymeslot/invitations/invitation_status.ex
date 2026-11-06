defmodule Tymeslot.Invitations.InvitationStatus do
  @moduledoc """
  The status of an invitation, derived from its meetings and never stored.

  A meeting *consumes* an invitation when it carries the invitation's id and
  either holds a slot, or was booked after the last reopen and is completed or
  was cancelled on an invitation that does not release on cancel (other than
  by an approval decline). A meeting holding a slot always counts, reopen or
  not: the database lets only one such meeting carry the invitation, and a
  reopen is refused while one does. Payment and approval timeouts record `:expired`, which
  never consumes. Precedence is used, revoked, expired, available.

  The database index guarantees only one *live* booking per invitation. On a
  `release_on_cancel: false` link, the "spent after cancellation" state is
  enforced only by the booking pre-check, so a very rare race (a check passes,
  another booking is made and cancelled, then the first inserts) can use such
  a link twice. This is accepted.
  """

  alias Tymeslot.Invitations.InvitationSchema
  alias Tymeslot.Meetings.{MeetingSchema, MeetingState}

  @type status :: :available | :used | :expired | :revoked

  @doc """
  The status at `now`, given the invitation's consuming meeting (see
  `consuming_meeting/2`), or nil when none consumes it.
  """
  @spec status(InvitationSchema.t(), MeetingSchema.t() | nil, DateTime.t()) :: status()
  def status(%InvitationSchema{}, %MeetingSchema{}, %DateTime{}), do: :used

  def status(%InvitationSchema{revoked_at: revoked_at} = invitation, nil, %DateTime{} = now) do
    cond do
      revoked_at -> :revoked
      expired?(invitation, now) -> :expired
      true -> :available
    end
  end

  @doc """
  The first of `meetings` (newest first) that uses `invitation` up, or nil.
  """
  @spec consuming_meeting(InvitationSchema.t(), [MeetingSchema.t()]) :: MeetingSchema.t() | nil
  def consuming_meeting(%InvitationSchema{} = invitation, meetings),
    do: Enum.find(meetings, &consumes?(invitation, &1))

  @doc "Whether `meeting` uses `invitation` up."
  @spec consumes?(InvitationSchema.t(), MeetingSchema.t()) :: boolean()
  def consumes?(%InvitationSchema{} = invitation, %MeetingSchema{} = meeting) do
    meeting.invitation_id == invitation.id and
      (meeting.status in MeetingState.occupying() or
         (booked_since_reopen?(invitation, meeting) and spent?(invitation, meeting)))
  end

  @doc """
  Whether the host may reopen the invitation: its consuming meeting no longer
  holds a slot.
  """
  @spec reopenable?(InvitationSchema.t(), MeetingSchema.t() | nil) :: boolean()
  def reopenable?(_invitation, nil), do: false

  def reopenable?(%InvitationSchema{} = invitation, %MeetingSchema{} = meeting) do
    consumes?(invitation, meeting) and meeting.status not in MeetingState.occupying()
  end

  defp expired?(%InvitationSchema{expires_at: nil}, _now), do: false

  defp expired?(%InvitationSchema{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp booked_since_reopen?(%InvitationSchema{reopened_at: nil}, _meeting), do: true

  defp booked_since_reopen?(%InvitationSchema{reopened_at: reopened_at}, meeting),
    do: DateTime.compare(meeting.inserted_at, reopened_at) != :lt

  # A finished meeting that still uses the invitation up.
  defp spent?(_invitation, %MeetingSchema{status: :completed}), do: true

  defp spent?(invitation, %MeetingSchema{status: :cancelled} = meeting),
    do: not invitation.release_on_cancel and is_nil(meeting.approval_declined_at)

  defp spent?(_invitation, _meeting), do: false
end
