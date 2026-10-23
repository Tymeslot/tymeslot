defmodule TymeslotWeb.Dashboard.PollParticipationTest do
  @moduledoc """
  Covers who is on a poll as the host's results panel shows it: link requests
  nobody has voted with yet, inviting people by email, and the line naming
  whoever has not voted.
  """
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  defp leave(name, key, room),
    do: :ok = RateLimiter.consume(name, key, RateLimiter.remaining(name, key) - room)

  describe "Poll participation" do
    setup %{conn: conn} do
      TestMocks.setup_calendar_mocks(events: [])

      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, username: "participationhost", timezone: "Europe/Tallinn")
      insert(:calendar_integration, user: user, is_active: true)

      {:ok, conn: log_in(conn, user), user: user}
    end

    # An open poll with one future slot and two voters, Alice and Bob.
    defp open_poll_with_votes(user) do
      poll = insert(:poll, user: user, title: "Team offsite", status: :open, meeting_type_id: nil)
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour)
        )

      for {name, email} <- [{"Alice", "alice@example.com"}, {"Bob", "bob@example.com"}] do
        participant =
          insert(:poll_participant,
            poll: poll,
            name: name,
            email: email,
            voted_at: DateTime.utc_now(:second)
          )

        insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)
      end

      %{poll: poll}
    end

    defp select_poll(view, poll) do
      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()
    end

    test "counts link requests nobody has voted with apart from the voters", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)
      now = DateTime.utc_now(:second)

      insert(:poll_participant, poll: poll, name: "Pending", confirmed_at: nil, link_sent_at: now)

      insert(:poll_participant,
        poll: poll,
        name: "Expired",
        confirmed_at: nil,
        inserted_at: DateTime.add(now, -3, :day),
        link_sent_at: DateTime.add(now, -3, :day)
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      html = select_poll(view, poll)

      assert html =~ "2 guests have voted so far."

      assert has_element?(
               view,
               "[data-testid='poll-unconfirmed-count']",
               "1 more person asked for a voting link"
             )

      refute html =~ "Pending"
    end

    test "invites more people to an open poll and names who has not voted yet", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)
      refute has_element?(view, "[data-testid='poll-waiting-for']")

      html =
        view
        |> form("form[data-testid='poll-invite-form']", %{
          "invite" => %{"emails" => "Grace <grace@example.com>\nalice@example.com"}
        })
        |> render_submit()

      # The flash is sent to the LiveView process, so it shows on the next render.
      assert render(view) =~ "Invitation sent to 1 person. 1 address was already on the poll."
      assert has_element?(view, "[data-testid='poll-waiting-for']", "Grace")
      assert html =~ "2 guests have voted so far."

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      grace = Enum.find(reloaded.participants, &(&1.email == "grace@example.com"))

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_invitation", "participant_id" => grace.id}
      )
    end

    test "keeps the addresses and explains when an invitation fails", %{conn: conn, user: user} do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      html =
        view
        |> form("form[data-testid='poll-invite-form']", %{"invite" => %{"emails" => "nope"}})
        |> render_submit()

      assert html =~ "Not valid email addresses: nope"

      html =
        view
        |> form("form[data-testid='poll-invite-form']", %{"invite" => %{"emails" => " "}})
        |> render_submit()

      assert html =~ "Enter at least one email address."
    end

    test "names the invitee names that can't be used and invites nobody", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      view
      |> form("form[data-testid='poll-invite-form']", %{
        "invite" => %{"emails" => "grace@example.com\nA <a@example.com>"}
      })
      |> render_submit()

      assert has_element?(
               view,
               "form[data-testid='poll-invite-form'] [data-testid='poll-invitees']",
               "These names can't be used: A"
             )

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)

      refute Enum.any?(
               reloaded.participants,
               &(&1.email in ["grace@example.com", "a@example.com"])
             )
    end

    test "refuses the whole list and says how many more the host can invite", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)
      leave(:poll_host_invitations, user.id, 1)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      html =
        view
        |> form("form[data-testid='poll-invite-form']", %{
          "invite" => %{"emails" => "grace@example.com, hedy@example.com"}
        })
        |> render_submit()

      assert html =~ "You can invite up to 1 more person right now."
      assert html =~ "grace@example.com, hedy@example.com"

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      refute Enum.any?(reloaded.participants, &(&1.email == "grace@example.com"))
      assert all_enqueued(worker: EmailWorker, args: %{"action" => "send_poll_invitation"}) == []
    end

    test "invites the rest and reports an address that has had too many emails", %{
      conn: conn,
      user: user
    } do
      %{poll: poll} = open_poll_with_votes(user)
      leave(:poll_recipient_email, "grace@example.com", 0)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      view
      |> form("form[data-testid='poll-invite-form']", %{
        "invite" => %{"emails" => "grace@example.com\nhedy@example.com"}
      })
      |> render_submit()

      assert render(view) =~
               "Invitation sent to 1 person. 1 address has had too many emails recently and was not invited."

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      refute Enum.any?(reloaded.participants, &(&1.email == "grace@example.com"))
      assert Enum.any?(reloaded.participants, &(&1.email == "hedy@example.com"))
    end
  end
end
