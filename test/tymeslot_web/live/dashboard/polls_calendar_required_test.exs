defmodule TymeslotWeb.Dashboard.PollsCalendarRequiredTest do
  @moduledoc """
  The poll dashboard around the host's calendar: without one there is no way
  to start a poll or invite anyone, since the voting page stays closed; with
  one, the form validates what the host types and the confirmation says when
  a time clashes with the calendar.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.PollDashboardHelpers

  alias Tymeslot.Polls
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])
    Gettext.put_locale(TymeslotWeb.Gettext, "en")

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "calhost", timezone: "Etc/UTC")

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    %{conn: conn, user: user}
  end

  defp select_poll(view, poll) do
    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()
  end

  defp open_poll(user) do
    poll = insert(:poll, user: user, status: :open, timezone: "Etc/UTC", meeting_type_id: nil)
    base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    slot =
      insert(:poll_time_slot,
        poll: poll,
        start_time: base,
        end_time: DateTime.add(base, 1, :hour)
      )

    %{poll: poll, slot: slot}
  end

  describe "without a calendar" do
    test "asks for one instead of offering a new poll", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      assert has_element?(view, "[data-testid='polls-connect-calendar']", "Connect a calendar")
      refute has_element?(view, "button", "New poll")

      # A forged event opens nothing either.
      view
      |> with_target("[data-phx-component]:has(> div > #polls-container)")
      |> render_click("new_poll", %{})

      refute has_element?(view, "form[phx-submit='create_poll']")
      assert Polls.list_polls(user.id) == []
    end

    test "an earlier poll keeps its results but cannot invite anyone", %{conn: conn, user: user} do
      %{poll: poll} = open_poll(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      assert has_element?(view, "[data-testid='polls-connect-calendar']")
      refute has_element?(view, "button", "New poll")

      select_poll(view, poll)
      await_slot_health(view)

      refute has_element?(view, "[data-testid='poll-invite-form']")
      assert has_element?(view, "[data-testid='poll-invite-closed']", "Connect a calendar first")
    end
  end

  describe "with a calendar" do
    setup %{user: user} do
      insert(:calendar_integration, user: user, provider: "debug")
      :ok
    end

    test "offers a new poll and counts its times against the limit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      refute has_element?(view, "[data-testid='polls-connect-calendar']")

      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()

      assert render(view) =~ "1 of 40 times"
    end

    test "refuses a duration that is not a usable length", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      for duration <- ["0", ""] do
        html =
          view
          |> form("form[phx-submit='create_poll']", %{
            "poll" => %{
              "title" => "Sync",
              "duration" => duration,
              "slots" => %{"0" => "#{date}T09:00"}
            }
          })
          |> render_submit()

        assert html =~ "Duration" and has_element?(view, "form[phx-submit='create_poll']")
      end

      assert Polls.list_polls(user.id) == []
    end

    test "the confirmation warns about a time that clashes with the calendar",
         %{conn: conn, user: user} do
      %{poll: poll, slot: slot} = open_poll(user)

      TestMocks.setup_calendar_mocks(
        events: [
          %{
            summary: "Busy",
            start_time: DateTime.add(slot.start_time, 15, :minute),
            end_time: DateTime.add(slot.end_time, 15, :minute)
          }
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      wait_until(fn ->
        assert has_element?(view, "#poll-slot-#{slot.id}", "Calendar conflict")
        :ok
      end)

      view
      |> element("#poll-slot-#{slot.id} button[phx-click='request_confirm_slot']")
      |> render_click()

      assert has_element?(view, "#confirm-slot-modal [data-testid='confirm-slot-conflict']")
    end

    test "the confirmation says nothing of a clash for a free time", %{conn: conn, user: user} do
      %{poll: poll, slot: slot} = open_poll(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)
      await_slot_health(view)

      view
      |> element("#poll-slot-#{slot.id} button[phx-click='request_confirm_slot']")
      |> render_click()

      assert has_element?(view, "#confirm-slot-modal")
      refute has_element?(view, "[data-testid='confirm-slot-conflict']")
    end
  end
end
