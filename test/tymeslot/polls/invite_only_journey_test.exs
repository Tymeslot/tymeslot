defmodule Tymeslot.Polls.InviteOnlyJourneyTest do
  @moduledoc """
  The invite-only journey end to end: the host creates a poll with an invitee
  in the dashboard, which presets it to invited people only; the invitee
  votes through the link in their invitation email; someone holding only the
  poll's shared link is told it is by invitation and cannot get a link.
  Only the calendar boundary is stubbed.
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

  test "an invitee votes through their invitation and the shared link takes no requests" do
    %{user: user, profile: profile} = seed_booking_account("1", "invite-journey", "Etc/UTC")

    user =
      user
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    host =
      ConnTest.build_conn()
      |> init_test_session(%{})
      |> fetch_session()
      |> log_in_user(user)

    # The host creates the poll with one invitee; listing her presets the
    # poll to invited people only.
    {:ok, dashboard, _html} = live(host, ~p"/dashboard/polls")
    dashboard |> element("button", "New poll") |> render_click()
    dashboard |> element("button", "Add time") |> render_click()
    date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

    params = %{
      "title" => "Board meeting",
      "duration" => "30",
      "timezone" => "Europe/Berlin",
      "slots" => %{"0" => "#{date}T09:00"},
      "invitees" => "Grace Hopper <grace@example.com>"
    }

    dashboard |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_change()
    assert has_element?(dashboard, "input[name='poll[access]'][value='invited'][checked]")
    dashboard |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_submit()

    assert [poll] = Polls.list_polls(user.id)
    assert poll.invite_only
    [slot] = poll.time_slots

    # Grace follows the link out of her invitation email and votes.
    grace = Repo.get_by!(PollParticipantSchema, poll_id: poll.id, email: "grace@example.com")

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

    # Someone holding only the shared link is told it is by invitation, gets
    # no form, and a request sent anyway changes nothing.
    {:ok, stranger, _html} =
      live(ConnTest.build_conn(), "/#{profile.username}/poll/#{poll.token}")

    assert has_element?(stranger, "[data-testid='poll-invite-only']")
    refute has_element?(stranger, "form[data-testid='poll-register-form']")

    render_hook(stranger, "register_participant", %{
      "name" => "Mallory",
      "email" => "mallory@example.com"
    })

    refute Repo.get_by(PollParticipantSchema, poll_id: poll.id, email: "mallory@example.com")
    refute_enqueued(worker: EmailWorker, args: %{"action" => "send_poll_participant_link"})
  end
end
