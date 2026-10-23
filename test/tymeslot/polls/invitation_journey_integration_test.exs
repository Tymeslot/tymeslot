defmodule Tymeslot.Polls.InvitationJourneyIntegrationTest do
  @moduledoc """
  The journey of a poll the host sends by email: the host invites people by
  address, invitees follow the link out of their invitation and vote, one
  never answers, and the host confirms a time. Everyone invited is a guest of
  the meeting the poll becomes and is sent its confirmation as one, the
  invitee who never voted included.

  Stubs only the external boundaries: the host's calendar, and the email
  service the meeting's confirmation goes through (`Tymeslot.EmailServiceMock`).
  The poll emails go through the real mailer, routed to the test process.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :polls

  import Mox
  import Swoosh.TestAssertions
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Phoenix.ConnTest
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{Confirm, Invitations, PollParticipantSchema}
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  # The poll emails are delivered inside the CircuitBreaker GenServer; global
  # mode routes them to the test process.
  setup :set_swoosh_global
  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Confirming checks the host's calendar for conflicts.
    TestMocks.setup_calendar_mocks()
    :ok
  end

  test "invitees vote from their invitations and all become guests of the confirmed meeting" do
    %{user: user, profile: profile} =
      seed_booking_account("1", "invite-journey-host", "Etc/UTC")

    base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    slots =
      for offset <- [0, 1] do
        start_time = DateTime.add(base, offset, :hour)
        %{start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)}
      end

    {:ok, invitees} =
      Invitations.parse(
        "Ada Lovelace <ada@example.com>\ncora@example.com, Bob Stone <bob@example.com>"
      )

    {:ok, poll} =
      Polls.create_poll(user.id, %{
        title: "Roadmap review",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: slots,
        invitees: invitees
      })

    [early, late] = poll.time_slots

    vote_from_invitation(profile.username, poll, "ada@example.com", %{
      "votes" => %{early.id => "yes", late.id => "no"}
    })

    # Invited by address alone, Cora gives her name with her responses.
    vote_from_invitation(profile.username, poll, "cora@example.com", %{
      "name" => "Cora Diaz",
      "votes" => %{early.id => "if_need_be", late.id => "yes"}
    })

    assert Repo.get_by!(PollParticipantSchema, poll_id: poll.id, email: "cora@example.com").name ==
             "Cora Diaz"

    # Bob never answers.
    assert Repo.get_by!(PollParticipantSchema, poll_id: poll.id, email: "bob@example.com").voted_at ==
             nil

    test_pid = self()

    expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, details ->
      assert details.host_managed
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_guest_confirmation, 3, fn email, details ->
      assert details.guest_decline_url
      send(test_pid, {:guest_confirmation, email})
      {:ok, "sent"}
    end)

    assert {:ok, meeting} = Confirm.confirm(poll.id, early.id, user.id)

    # The host manages the meeting; Ada, the first available, only fills the
    # attendee fields a calendar entry needs.
    assert meeting.managed_by_host
    assert meeting.attendee_email == "ada@example.com"

    assert meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email) |> Enum.sort() ==
             ["ada@example.com", "bob@example.com", "cora@example.com"]

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
    )

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_confirmation_emails",
               "meeting_id" => meeting.id
             })

    assert_received {:guest_confirmation, "ada@example.com"}
    assert_received {:guest_confirmation, "bob@example.com"}
    assert_received {:guest_confirmation, "cora@example.com"}
  end

  # Sends `email`'s invitation, follows the personal link out of it on a fresh
  # connection, and submits `form` on the voting page it opens.
  defp vote_from_invitation(username, poll, email, form) do
    participant = Repo.get_by!(PollParticipantSchema, poll_id: poll.id, email: email)

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_poll_invitation", "participant_id" => participant.id}
    )

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_poll_invitation",
               "participant_id" => participant.id
             })

    assert_received {:email, %{to: [{_name, ^email}], text_body: text_body}}
    [link] = Regex.run(~r{https?://\S+\?p=[\w-]+}, text_body)
    uri = URI.parse(link)
    assert uri.path == "/#{username}/poll/#{poll.token}"

    {:ok, view, _html} = live(ConnTest.build_conn(), "#{uri.path}?#{uri.query}")

    view
    |> form("form[data-testid='poll-vote-form']", form)
    |> render_submit()

    assert %DateTime{} = Repo.reload(participant).voted_at
  end
end
