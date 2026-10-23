defmodule Tymeslot.Polls.ResendInvitationJourneyTest do
  @moduledoc """
  A lost invitation, end to end: the host invites someone to an invite-only
  poll, the invitation never reaches her inbox, the host sends it again from
  the poll editor (held back while the first one is minutes old), and she
  votes through the link in the new email. Only the calendar boundary is
  stubbed.
  """
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :polls

  import Swoosh.TestAssertions
  import Tymeslot.AuthTestHelpers
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Phoenix.ConnTest
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  # The email is delivered inside the circuit breaker's process; global mode
  # routes it to the test process.
  setup :set_swoosh_global

  setup do
    TestMocks.setup_calendar_mocks(events: [])
    :ok
  end

  defp invitation_jobs(participant) do
    all_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_poll_invitation", "participant_id" => participant.id}
    )
  end

  test "the host sends a lost invitation again and the invitee votes through it" do
    %{user: user} = seed_booking_account("1", "resend-journey", "Etc/UTC")

    user =
      user
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    start_time = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

    {:ok, poll} =
      Polls.create_poll(user.id, %{
        title: "Board meeting",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [%{start_time: start_time}],
        invitees: [%{email: "grace@example.com", name: "Grace Hopper"}]
      })

    assert poll.invite_only
    [slot] = poll.time_slots
    grace = Repo.get_by!(PollParticipantSchema, poll_id: poll.id, email: "grace@example.com")

    # Her invitation was sent and lost: its job is never performed here.
    assert [_first] = invitation_jobs(grace)

    host =
      ConnTest.build_conn()
      |> init_test_session(%{})
      |> fetch_session()
      |> log_in_user(user)

    {:ok, dashboard, _html} = live(host, ~p"/dashboard/polls")

    dashboard
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()

    dashboard |> element("[data-testid='poll-edit-details']") |> render_click()
    resend = "[data-testid='poll-resend-invitation'][phx-value-id='#{grace.id}']"
    assert has_element?(dashboard, resend <> "[aria-label='Resend invitation to Grace Hopper']")

    # Minutes after the invitation, a resend is held back.
    dashboard |> element(resend) |> render_click()
    assert render(dashboard) =~ "Grace Hopper was sent their link a few minutes ago."
    assert [_first] = invitation_jobs(grace)

    # Later, the host tries again and the invitation goes out a second time.
    grace
    |> Changeset.change(link_sent_at: DateTime.add(DateTime.utc_now(:second), -11, :minute))
    |> Repo.update!()

    dashboard |> element(resend) |> render_click()
    assert render(dashboard) =~ "Sent Grace Hopper their link again."
    assert [_first, _again] = invitation_jobs(grace)

    # Grace follows the link out of the new email and votes.
    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_poll_invitation",
               "participant_id" => grace.id
             })

    assert_received {:email, %{to: [{_name, "grace@example.com"}], text_body: text_body}}
    [link] = Regex.run(~r{https?://\S+\?p=[\w-]+}, text_body)
    uri = URI.parse(link)

    {:ok, ballot, _html} = live(ConnTest.build_conn(), "#{uri.path}?#{uri.query}")

    ballot
    |> form("form[data-testid='poll-vote-form']", %{"votes" => %{slot.id => "yes"}})
    |> render_submit()

    assert %DateTime{} = Repo.get!(PollParticipantSchema, grace.id).voted_at
  end
end
