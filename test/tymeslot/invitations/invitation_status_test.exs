defmodule Tymeslot.Invitations.InvitationStatusTest do
  use ExUnit.Case, async: true

  @moduletag :bookings

  alias Tymeslot.Invitations.{InvitationSchema, InvitationStatus}
  alias Tymeslot.Meetings.MeetingSchema

  @now ~U[2026-11-06 12:00:00Z]

  defp invitation(attrs \\ []) do
    struct!(%InvitationSchema{id: 7, release_on_cancel: true}, attrs)
  end

  defp meeting(status, attrs \\ []) do
    struct!(
      %MeetingSchema{
        invitation_id: 7,
        status: status,
        inserted_at: ~U[2026-11-05 12:00:00Z]
      },
      attrs
    )
  end

  # credo:disable-for-next-line CredoChecks.ThinWrapperFunctions
  defp status(invitation, meeting \\ nil), do: InvitationStatus.status(invitation, meeting, @now)

  test "no meetings and no expiry is available" do
    assert status(invitation()) == :available
  end

  test "an expiry in the past is expired" do
    assert status(invitation(expires_at: DateTime.add(@now, -1, :second))) == :expired
  end

  test "an expiry exactly now is expired, one second ahead is available" do
    assert status(invitation(expires_at: @now)) == :expired
    assert status(invitation(expires_at: DateTime.add(@now, 1, :second))) == :available
  end

  test "a revoked invitation is revoked" do
    assert status(invitation(revoked_at: ~U[2026-11-05 00:00:00Z])) == :revoked
  end

  test "a confirmed meeting uses the invitation" do
    assert status(invitation(), meeting(:confirmed)) == :used
  end

  test "a meeting awaiting payment uses the invitation" do
    assert status(invitation(), meeting(:awaiting_payment)) == :used
  end

  test "a completed meeting uses the invitation" do
    assert status(invitation(), meeting(:completed)) == :used
  end

  test "an expired meeting does not use the invitation" do
    assert status(invitation(), meeting(:expired)) == :available
  end

  test "a cancelled meeting frees an invitation that releases on cancel" do
    assert status(invitation(release_on_cancel: true), meeting(:cancelled)) == :available
  end

  test "a cancelled meeting keeps using an invitation that does not release on cancel" do
    assert status(invitation(release_on_cancel: false), meeting(:cancelled)) == :used
  end

  test "a declined approval never uses the invitation up" do
    declined = meeting(:cancelled, approval_declined_at: ~U[2026-11-05 13:00:00Z])
    assert status(invitation(release_on_cancel: false), declined) == :available
  end

  test "a finished meeting booked before the reopen no longer counts" do
    reopened = invitation(release_on_cancel: false, reopened_at: ~U[2026-11-05 18:00:00Z])
    assert status(reopened, meeting(:cancelled)) == :available
    assert status(reopened, meeting(:completed)) == :available
  end

  test "a finished meeting booked after the reopen counts" do
    reopened = invitation(release_on_cancel: false, reopened_at: ~U[2026-11-05 06:00:00Z])
    assert status(reopened, meeting(:cancelled)) == :used
  end

  test "a live booking counts whenever it was made relative to the reopen" do
    reopened = invitation(reopened_at: ~U[2026-11-05 12:00:00Z])
    assert status(reopened, meeting(:confirmed)) == :used
    assert status(reopened, meeting(:confirmed, inserted_at: ~U[2026-11-05 11:00:00Z])) == :used
  end

  test "used takes precedence over revoked and expired" do
    inv = invitation(revoked_at: ~U[2026-11-05 00:00:00Z], expires_at: ~U[2026-11-01 00:00:00Z])
    assert status(inv, meeting(:confirmed)) == :used
  end

  test "revoked takes precedence over expired" do
    inv = invitation(revoked_at: ~U[2026-11-05 00:00:00Z], expires_at: ~U[2026-11-01 00:00:00Z])
    assert status(inv) == :revoked
  end

  test "a meeting carrying another invitation does not consume this one" do
    refute InvitationStatus.consumes?(invitation(), meeting(:confirmed, invitation_id: 8))
  end

  describe "reopenable?/2" do
    test "is false while a booking holds a slot" do
      refute InvitationStatus.reopenable?(invitation(), meeting(:confirmed))
    end

    test "is true for a cancelled meeting when the invitation does not release on cancel" do
      assert InvitationStatus.reopenable?(
               invitation(release_on_cancel: false),
               meeting(:cancelled)
             )
    end

    test "is true for a completed meeting" do
      assert InvitationStatus.reopenable?(invitation(), meeting(:completed))
    end

    test "is false with no meeting" do
      refute InvitationStatus.reopenable?(invitation(), nil)
    end
  end
end
