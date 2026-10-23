defmodule TymeslotWeb.Dashboard.PollUsernameTest do
  @moduledoc """
  A host without a username is told to set one when they list invitees,
  rather than having the invitations discarded after they were sent.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: nil)
    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    %{conn: conn, user: user}
  end

  test "creating a poll with invitees asks the host to set a username first", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/polls")

    view |> element("button", "New poll") |> render_click()
    view |> element("button", "Add time") |> render_click()
    date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

    html =
      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Launch planning",
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00"},
          "invitees" => "ada@example.com"
        }
      })
      |> render_submit()

    assert html =~ "Set a username in your profile first"
    assert Polls.list_polls(ctx.user.id) == []
    assert all_enqueued(worker: EmailWorker) == []
  end
end
