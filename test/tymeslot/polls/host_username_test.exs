defmodule Tymeslot.Polls.HostUsernameTest do
  @moduledoc """
  Every email to a participant links to the voting page under the host's
  username, so a host without one cannot invite anyone: refused up front,
  before any invitation is counted against their limits or queued.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user)
    insert(:profile, user: user, username: nil)
    insert(:calendar_integration, user: user, provider: "debug")

    start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    attrs = %{
      title: "Team sync",
      duration_minutes: 30,
      timezone: "Etc/UTC",
      slots: [%{start_time: start_time}]
    }

    %{user: user, attrs: attrs}
  end

  describe "create_poll/2" do
    test "refuses invitees and creates nothing", %{user: user, attrs: attrs} do
      assert {:error, :no_username} =
               Polls.create_poll(user.id, Map.put(attrs, :invitees, [%{email: "a@example.com"}]))

      assert Polls.list_polls(user.id) == []
      assert all_enqueued(worker: EmailWorker) == []
    end

    test "still creates a poll shared by its link", %{user: user, attrs: attrs} do
      assert {:ok, _poll} = Polls.create_poll(user.id, attrs)
    end
  end

  describe "invite_participants/3" do
    test "refuses to invite anyone", %{user: user} do
      poll = insert(:poll, user: user)

      assert {:error, :no_username} =
               Polls.invite_participants(poll.id, user.id, [%{email: "a@example.com", name: nil}])

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "a@example.com") == nil
      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "resend_invitation/3" do
    test "refuses to send a link again", %{user: user} do
      poll = insert(:poll, user: user)
      now = DateTime.utc_now(:second)

      participant =
        insert(:poll_participant,
          poll: poll,
          email: "ada@example.com",
          invited_at: now,
          confirmed_at: now,
          link_sent_at: DateTime.add(now, -1, :day)
        )

      assert {:error, :no_username} = Polls.resend_invitation(poll.id, user.id, participant.id)
      assert all_enqueued(worker: EmailWorker) == []
    end
  end
end
