defmodule Tymeslot.Repo.Migrations.EncryptAndHashLinkTokensTest do
  @moduledoc """
  Poll, participant, guest RSVP and free/busy tokens were stored as
  themselves. The migration encrypts each and backfills its hash, so links
  already handed out keep working, and keeps the plain token, which the
  previous release still reads if the image is rolled back.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :security
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.FreeBusy
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_002_052_859

  test "links handed out by the previous release keep working" do
    poll = insert(:poll)
    participant = insert(:poll_participant, poll: poll)
    {:ok, guest} = GuestQueries.insert_guest(%{meeting_id: insert(:meeting).id, email: "g@x.io"})
    {:ok, profile} = FreeBusy.enable_feed(insert(:profile))

    # Rolling back writes each token into its plain column, as the previous
    # release kept it, so going up again meets rows as that release left
    # them.
    MigrationRunner.rerun!(@version)

    assert {:ok, %{id: poll_id}} = Polls.get_poll_for_voting(poll.token)
    assert poll_id == poll.id

    assert Voting.get_participant(poll, participant.token).id == participant.id

    assert {:ok, %{id: guest_id}} = GuestQueries.get_by_token(guest.rsvp_token)
    assert guest_id == guest.id

    assert {:ok, %{id: profile_id}} = FreeBusy.get_profile_by_token(profile.freebusy_token)
    assert profile_id == profile.id

    for {table, id, column, token} <- [
          {"polls", poll.id, "token", poll.token},
          {"poll_participants", participant.id, "token", participant.token},
          {"meeting_guests", guest.id, "rsvp_token", guest.rsvp_token},
          {"profiles", profile.id, "freebusy_token", profile.freebusy_token}
        ] do
      %{rows: [[plain]]} =
        Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [dump_id(id)])

      assert plain == token
    end
  end

  test "rolling back restores each plain token from its encrypted value, over a stale copy" do
    {:ok, profile} = FreeBusy.enable_feed(insert(:profile))
    poll = insert(:poll)

    # A plain copy left behind by something other than the application, which
    # empties it whenever the token changes: the encrypted token is current.
    Repo.query!("UPDATE profiles SET freebusy_token = 'stale' WHERE id = $1", [profile.id])
    Repo.query!("UPDATE polls SET token = 'stale' WHERE id = $1", [UUID.dump!(poll.id)])

    MigrationRunner.down!(@version)

    assert plain("profiles", profile.id, "freebusy_token") == profile.freebusy_token
    assert plain("polls", poll.id, "token") == poll.token
  end

  test "rolling back leaves a disabled feed without a token" do
    {:ok, profile} = FreeBusy.enable_feed(insert(:profile))

    Repo.query!("UPDATE profiles SET freebusy_token = $1 WHERE id = $2", [
      profile.freebusy_token,
      profile.id
    ])

    {:ok, _profile} = FreeBusy.disable_feed(profile)

    MigrationRunner.down!(@version)

    assert plain("profiles", profile.id, "freebusy_token") == nil
  end

  defp plain(table, id, column) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [dump_id(id)])

    value
  end

  defp dump_id(id) when is_integer(id), do: id
  defp dump_id(id), do: UUID.dump!(id)
end
