defmodule TymeslotWeb.Dashboard.PollEmailLimitsTest do
  @moduledoc """
  What the create form says when the poll email limits turn an invitation
  away.
  """
  # async: false: these tests fill shared rate-limit buckets, which another
  # module's setup would otherwise clear mid-test.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Security.RateLimiter

  setup do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")
    insert(:calendar_integration, user: user, provider: "debug")

    conn =
      build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    {:ok, conn: conn, user: user}
  end

  defp leave(name, key, room),
    do: :ok = RateLimiter.consume(name, key, RateLimiter.remaining(name, key) - room)

  defp submit_poll(conn, invitees) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> element("button", "New poll") |> render_click()
    view |> element("button", "Add time") |> render_click()
    date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

    view
    |> form("form[phx-submit='create_poll']", %{
      "poll" => %{
        "title" => "Launch planning",
        "duration" => "30",
        "timezone" => "Europe/Tallinn",
        "slots" => %{"0" => "#{date}T09:00"},
        "invitees" => invitees
      }
    })
    |> render_submit()

    view
  end

  test "creates nothing when the host can invite nobody else right now", %{
    conn: conn,
    user: user
  } do
    leave(:poll_host_invitations, user.id, 0)

    view = submit_poll(conn, "ada@example.com")

    assert render(view) =~ "You can&#39;t invite anyone else right now. Please try again later."
    assert Polls.list_polls(user.id) == []
  end

  test "creates the poll and reports an invitee who has had too many emails", %{
    conn: conn,
    user: user
  } do
    leave(:poll_recipient_email, "grace@example.com", 0)

    view = submit_poll(conn, "grace@example.com, ada@example.com")

    assert render(view) =~
             "Poll created. 1 address has had too many emails recently and was not invited."

    assert [poll] = Polls.list_polls(user.id)
    assert Enum.map(poll.participants, & &1.email) == ["ada@example.com"]
  end
end
