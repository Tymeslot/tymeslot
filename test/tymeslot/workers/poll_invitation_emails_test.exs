defmodule Tymeslot.Workers.PollInvitationEmailsTest do
  @moduledoc """
  Covers the EmailWorker action that sends a poll invitation: the invitee's
  personal link, the candidate times and the host's note.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :emails

  import Swoosh.TestAssertions
  import Tymeslot.Factory

  alias Tymeslot.Workers.EmailWorker

  # Delivery runs inside the CircuitBreaker GenServer; global mode routes the
  # email to the test process. It requires `async: false`.
  setup :set_swoosh_global

  describe "send_poll_invitation" do
    test "invites the participant with their link, the proposed times and the host's note" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "hostname")

      poll =
        insert(:poll,
          status: :open,
          user: user,
          title: "Team sync",
          description: "Bring the roadmap.",
          timezone: "Etc/UTC"
        )

      start_time = ~U[2030-03-04 10:00:00Z]

      insert(:poll_time_slot,
        poll: poll,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour)
      )

      invitee = insert(:poll_participant, poll: poll, name: nil, email: "ada@example.com")

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_invitation",
                 "participant_id" => invitee.id
               })

      assert_receive {:email, email}, 1000
      assert email.to == [{"", "ada@example.com"}]
      assert email.subject =~ "Team sync"
      assert email.text_body =~ "/hostname/poll/#{poll.token}?p=#{invitee.token}"
      assert email.text_body =~ "Bring the roadmap."
      assert email.text_body =~ "2030"
    end

    test "is not sent while the host's account is about to be deleted" do
      user = insert(:user, deletion_scheduled_at: DateTime.utc_now(:second))
      _profile = insert(:profile, user: user, username: "hostname")
      poll = insert(:poll, status: :open, user: user)
      invitee = insert(:poll_participant, poll: poll, email: "ada@example.com")

      assert {:discard, "host account pending deletion"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_invitation",
                 "participant_id" => invitee.id
               })

      refute_receive {:email, _any}, 200
    end
  end
end
