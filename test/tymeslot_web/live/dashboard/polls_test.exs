defmodule TymeslotWeb.Dashboard.PollsTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls

  # A host with a profile but no calendar integration and no username: the
  # baseline for list/create/validation tests.
  defp setup_host(_context) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)
    {:ok, conn: log_in(build_conn(), user), user: user, profile: profile}
  end

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  # ===========================================================================
  # Listing
  # ===========================================================================

  describe "Poll list" do
    setup :setup_host

    test "lists existing polls with their titles and status", %{conn: conn, user: user} do
      open_poll = insert(:poll, user: user, title: "Team sync", status: :open)
      base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      insert(:poll_time_slot, poll: open_poll, start_time: base)
      insert(:poll_time_slot, poll: open_poll, start_time: DateTime.add(base, 1, :hour))
      insert(:poll, user: user, title: "Roadmap review", status: :confirmed)

      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      assert html =~ "Team sync"
      assert html =~ "Roadmap review"
      assert html =~ "Open"
      assert html =~ "Confirmed"
      assert html =~ "2 time options"
    end

    test "shows an empty state when the user has no polls", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      assert html =~ "No polls yet"
    end

    test "does not list polls belonging to other users", %{conn: conn} do
      other = insert(:user)
      insert(:poll, user: other, title: "Someone else's poll")

      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      refute html =~ "Someone else's poll"
    end
  end

  # ===========================================================================
  # Creating
  # ===========================================================================

  describe "Creating a poll" do
    setup :setup_host

    test "creates a poll with candidate slots and shows it in the list", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()

      # Two candidate-slot rows.
      view |> element("button", "Add time") |> render_click()
      view |> element("button", "Add time") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Launch planning",
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00", "1" => "#{date}T10:00"}
        }
      })
      |> render_submit()

      assert render(view) =~ "Launch planning"

      assert [poll] = Polls.list_polls(user.id)
      assert poll.title == "Launch planning"
      assert length(poll.time_slots) == 2
    end

    test "shows an error and creates nothing when submitted with no slots", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()

      html =
        view
        |> form("form[phx-submit='create_poll']", %{
          "poll" => %{
            "title" => "Empty poll",
            "duration" => "30",
            "timezone" => "Europe/Tallinn"
          }
        })
        |> render_submit()

      assert html =~ "Add at least one candidate time"
      assert Polls.list_polls(user.id) == []
    end
  end

  # ===========================================================================
  # Share link gating
  # ===========================================================================

  describe "Share link" do
    test "is disabled with a connect-calendar tooltip when the host has no calendar", %{
      conn: conn
    } do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, username: "hostwithout")
      insert(:poll, user: user, title: "Needs a calendar")

      {:ok, _view, html} = live(log_in(conn, user), ~p"/dashboard/polls")

      assert html =~ "Connect a calendar in Calendar settings to enable this feature"
      refute html =~ ~s(phx-hook="CopyOnClick")
    end

    test "is enabled when the host has an active calendar integration", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, username: "hostwith")
      insert(:calendar_integration, user: user, is_active: true)
      poll = insert(:poll, user: user, title: "Ready to share")

      {:ok, _view, html} = live(log_in(conn, user), ~p"/dashboard/polls")

      assert html =~ ~s(phx-hook="CopyOnClick")
      assert html =~ "/hostwith/poll/#{poll.token}"
    end
  end
end
