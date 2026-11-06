defmodule Tymeslot.InvitationsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  import Tymeslot.Test.ClockHelpers

  alias Ecto.Changeset
  alias Tymeslot.Invitations
  alias Tymeslot.Invitations.InvitationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.Token

  setup do
    user = insert(:user)
    type = insert(:meeting_type, user: user, invitation_only: true)
    {:ok, user: user, type: type}
  end

  defp book(invitation, user, status, attrs \\ []) do
    insert(
      :meeting,
      Keyword.merge(
        [organizer_user: user, status: status, invitation_id: invitation.id],
        attrs
      )
    )
  end

  defp leave(name, key, room),
    do: :ok = RateLimiter.consume(name, key, RateLimiter.remaining(name, key) - room)

  describe "create/3" do
    test "on a type that is not invitation-only is refused", %{user: user} do
      open = insert(:meeting_type, user: user)

      assert Invitations.create(user.id, open, %{}) == {:error, :not_invitation_only}
      assert Repo.aggregate(InvitationSchema, :count) == 0
    end

    test "re-reads the type, so a stale invitation-only struct is refused", %{user: user} do
      open = insert(:meeting_type, user: user, invitation_only: false)
      stale = %{open | invitation_only: true}

      assert Invitations.create(user.id, stale, %{}) == {:error, :not_invitation_only}
      assert Repo.aggregate(InvitationSchema, :count) == 0
    end

    test "rejects a past expiry with a translatable message", %{user: user, type: type} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert {:error, changeset} = Invitations.create(user.id, type, %{expires_at: past})
      assert {"must be in the future", _opts} = changeset.errors[:expires_at]
    end

    test "on another host's type is refused", %{type: type} do
      other = insert(:user)

      assert Invitations.create(other.id, type, %{}) == {:error, :not_found}
      assert Repo.aggregate(InvitationSchema, :count) == 0
    end

    test "returns a token that resolves", %{user: user, type: type} do
      assert {:ok, invitation} =
               Invitations.create(user.id, type, %{name: " Ada ", email: "ADA@Example.com"})

      assert byte_size(invitation.token) > 20
      assert invitation.name == "Ada"
      assert invitation.email == "ada@example.com"
      assert {:ok, resolved} = Invitations.resolve(invitation.token)
      assert resolved.id == invitation.id
    end

    test "the token is stored only encrypted and hashed", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      %{rows: [[encrypted, hash]]} =
        Repo.query!(
          "SELECT token_encrypted, token_hash FROM meeting_type_invitations WHERE id = $1",
          [
            invitation.id
          ]
        )

      refute String.contains?(encrypted, invitation.token)
      refute String.contains?(hash, invitation.token)
      assert hash == Token.hash_token(invitation.token)
      refute inspect(invitation) =~ invitation.token
    end

    test "refuses an expiry in the past and an invalid address", %{user: user, type: type} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:error, %Changeset{} = changeset} =
               Invitations.create(user.id, type, %{expires_at: past, email: "not-an-email"})

      assert %{expires_at: [_expiry], email: [_email]} = errors_on(changeset)
    end

    test "is rate-limited per host", %{user: user, type: type} do
      leave(:invitation_create, user.id, 2)

      assert {:ok, _invitation} = Invitations.create(user.id, type, %{})
      assert {:ok, _invitation} = Invitations.create(user.id, type, %{})
      assert {:error, :rate_limited, _message} = Invitations.create(user.id, type, %{})
      assert Repo.aggregate(InvitationSchema, :count) == 2

      other = insert(:user)
      other_type = insert(:meeting_type, user: other, invitation_only: true)
      assert {:ok, _invitation} = Invitations.create(other.id, other_type, %{})
    end
  end

  describe "resolve/1" do
    test "reports why a link no longer works", %{user: user, type: type} do
      {:ok, used} = Invitations.create(user.id, type, %{})
      book(used, user, :confirmed)

      {:ok, revoked} = Invitations.create(user.id, type, %{})
      {:ok, _invitation} = Invitations.revoke(user.id, revoked.id)

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, expiring} = Invitations.create(user.id, type, %{expires_at: future})

      assert {:error, :used} = Invitations.resolve(used.token)
      assert {:error, :revoked} = Invitations.resolve(revoked.token)
      assert {:ok, _invitation} = Invitations.resolve(expiring.token)

      freeze_clock(DateTime.add(future, 1, :second))
      assert {:error, :expired} = Invitations.resolve(expiring.token)
    end

    test "is not found for garbage, nil, or an inactive type", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      assert {:error, :not_found} = Invitations.resolve("garbage")
      assert {:error, :not_found} = Invitations.resolve(nil)
      assert {:error, :not_found} = Invitations.resolve(42)

      type |> Changeset.change(is_active: false) |> Repo.update!()
      assert {:error, :not_found} = Invitations.resolve(invitation.token)
    end

    test "is not found once the type stops being invitation-only", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      type |> Changeset.change(invitation_only: false) |> Repo.update!()
      assert {:error, :not_found} = Invitations.resolve(invitation.token)
    end
  end

  describe "list/2" do
    test "shows each invitation's derived status with its meeting, newest first", %{
      user: user,
      type: type
    } do
      {:ok, first} = Invitations.create(user.id, type, %{})
      {:ok, second} = Invitations.create(user.id, type, %{})
      meeting = book(first, user, :confirmed)

      entries = Invitations.list(user.id, type)

      assert Enum.map(entries, & &1.invitation.id) == [second.id, first.id]

      assert [%{status: :available, meeting: nil}, %{status: :used, meeting: used_meeting}] =
               entries

      assert used_meeting.id == meeting.id
    end

    test "falls back to the latest meeting when none consumes the invitation", %{
      user: user,
      type: type
    } do
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      cancelled = book(invitation, user, :cancelled)

      assert [%{status: :available, meeting: %MeetingSchema{id: id}}] =
               Invitations.list(user.id, type)

      assert id == cancelled.id
    end

    test "keeps the newest when a limit is given", %{user: user, type: type} do
      {:ok, _oldest} = Invitations.create(user.id, type, %{})
      {:ok, middle} = Invitations.create(user.id, type, %{})
      {:ok, newest} = Invitations.create(user.id, type, %{})

      ids = user.id |> Invitations.list(type, limit: 2) |> Enum.map(& &1.invitation.id)

      assert ids == [newest.id, middle.id]
    end

    test "shows nothing to another host", %{user: user, type: type} do
      {:ok, _invitation} = Invitations.create(user.id, type, %{})

      assert Invitations.list(insert(:user).id, type) == []
    end
  end

  describe "revoke/2" do
    test "never touches the booking", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      meeting = book(invitation, user, :confirmed)

      assert {:ok, revoked} = Invitations.revoke(user.id, invitation.id)
      assert revoked.revoked_at
      assert Repo.reload!(meeting).status == :confirmed
    end

    test "is a no-op the second time and refuses another host's invitation", %{
      user: user,
      type: type
    } do
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      {:ok, first} = Invitations.revoke(user.id, invitation.id)
      {:ok, again} = Invitations.revoke(user.id, invitation.id)

      assert again.revoked_at == first.revoked_at
      assert {:error, :not_found} = Invitations.revoke(insert(:user).id, invitation.id)
    end
  end

  describe "reopen/2" do
    test "frees a used invitation whose meeting was cancelled", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{release_on_cancel: false})

      book(invitation, user, :cancelled,
        inserted_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
      )

      assert {:error, :used} = Invitations.resolve(invitation.token)
      assert {:ok, reopened} = Invitations.reopen(user.id, invitation.id)
      assert reopened.reopened_at
      assert {:ok, _invitation} = Invitations.resolve(invitation.token)
    end

    test "refuses while a booking holds the invitation", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      book(invitation, user, :confirmed)

      assert {:error, :not_reopenable} = Invitations.reopen(user.id, invitation.id)
    end

    test "refuses an invitation that is merely available", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      assert {:error, :not_reopenable} = Invitations.reopen(user.id, invitation.id)
    end

    test "refuses another host's invitation", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      {:ok, _invitation} = Invitations.revoke(user.id, invitation.id)

      assert Invitations.reopen(insert(:user).id, invitation.id) == {:error, :not_found}
      assert Repo.reload!(invitation).reopened_at == nil
    end

    test "makes a revoked invitation bookable again", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      {:ok, _invitation} = Invitations.revoke(user.id, invitation.id)

      assert {:ok, reopened} = Invitations.reopen(user.id, invitation.id)
      assert reopened.revoked_at == nil
      assert {:ok, _invitation} = Invitations.resolve(invitation.token)
    end
  end

  describe "check_claimable/2" do
    test "is ok only for an available invitation of that type", %{user: user, type: type} do
      other_type = insert(:meeting_type, user: user, invitation_only: true)
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      assert Invitations.check_claimable(invitation.id, type.id) == :ok

      assert Invitations.check_claimable(invitation.id, other_type.id) ==
               {:error, :invitation_unavailable}

      assert Invitations.check_claimable(0, type.id) == {:error, :invitation_unavailable}

      book(invitation, user, :pending)

      assert Invitations.check_claimable(invitation.id, type.id) ==
               {:error, :invitation_unavailable}
    end

    test "is refused once the type stops being invitation-only", %{user: user, type: type} do
      {:ok, invitation} = Invitations.create(user.id, type, %{})
      assert Invitations.check_claimable(invitation.id, type.id) == :ok

      type |> Changeset.change(invitation_only: false) |> Repo.update!()

      assert Invitations.check_claimable(invitation.id, type.id) ==
               {:error, :invitation_unavailable}
    end
  end
end
