defmodule TymeslotWeb.Dashboard.PollManagementTest do
  @moduledoc """
  Covers managing a poll from the dashboard: choosing its reminders, editing
  an open poll (deadline, reminders, new times), taking someone off it, and
  deleting a poll that is over.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "managehost", timezone: "Etc/UTC")
    insert(:calendar_integration, user: user, is_active: true)

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  describe "reminders in the create form" do
    test "start at a day before the deadline and take the presets", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()

      assert has_element?(view, "[data-testid='poll-reminders-form']", "1 day before")
      view |> element("[data-testid='reminder-preset-3-days']") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()
      deadline = Date.utc_today() |> Date.add(5) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Offsite",
          "duration" => "30",
          "timezone" => "Europe/Berlin",
          "deadline" => "#{deadline}T12:00",
          "slots" => %{"0" => "#{date}T09:00"}
        }
      })
      |> render_submit()

      assert [poll] = Polls.list_polls(user.id)

      assert PollSchema.reminders(poll) == [
               %{value: 1, unit: "days"},
               %{value: 3, unit: "days"}
             ]
    end
  end

  describe "editing an open poll" do
    setup %{user: user} do
      poll =
        insert(:poll,
          user: user,
          status: :open,
          title: "Offsite",
          timezone: "Etc/UTC",
          duration_minutes: 30,
          meeting_type_id: nil,
          deadline_at: in_days(3)
        )

      insert(:poll_time_slot, poll: poll, start_time: in_days(7), position: 0)
      %{poll: poll}
    end

    test "moves the deadline, changes the reminders and adds a time", %{
      conn: conn,
      user: user,
      poll: poll
    } do
      view = open_editor(conn, poll)

      view |> element("[data-testid='reminder-preset-3-days']") |> render_click()
      view |> element("[data-testid='poll-new-times'] button", "Add time") |> render_click()

      view
      |> form("[data-testid='poll-details-form']", %{
        "poll" => %{
          "title" => "Offsite",
          "deadline" => local(in_days(5)),
          "new_times" => %{"0" => local(in_days(9))}
        }
      })
      |> render_submit()

      {:ok, updated} = Polls.get_poll_for_host(poll.id, user.id)
      assert DateTime.compare(updated.deadline_at, in_days(4)) == :gt
      assert length(updated.time_slots) == 2

      assert PollSchema.reminders(updated) == [
               %{value: 1, unit: "days"},
               %{value: 3, unit: "days"}
             ]

      refute has_element?(view, "[data-testid='poll-details-form']")
    end

    test "keeps the editor open and explains a deadline in the past", %{conn: conn, poll: poll} do
      view = open_editor(conn, poll)

      html =
        view
        |> form("[data-testid='poll-details-form']", %{
          "poll" => %{"title" => "Offsite", "deadline" => local(in_days(-1))}
        })
        |> render_submit()

      assert html =~ "The deadline must be in the future"
      assert has_element?(view, "[data-testid='poll-details-form']")
    end

    test "takes someone off the poll", %{conn: conn, poll: poll} do
      participant = insert(:poll_participant, poll: poll, name: "Joker")
      view = open_editor(conn, poll)

      view |> element("[data-testid='poll-remove-participant']") |> render_click()

      assert Repo.get(PollParticipantSchema, participant.id) == nil
      refute render(view) =~ "Joker"
    end
  end

  describe "deleting a poll" do
    test "a poll that is over is deleted after a confirmation", %{conn: conn, user: user} do
      poll = insert(:poll, user: user, status: :cancelled, title: "Old test poll")
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      view |> element("[data-testid='poll-delete']") |> render_click()
      view |> element("#delete-poll-modal [data-testid='confirm-delete-poll']") |> render_click()

      assert Polls.list_polls(user.id) == []
      refute render(view) =~ "Old test poll"
    end

    test "an open poll offers no delete, only cancelling", %{conn: conn, user: user} do
      poll = insert(:poll, user: user, status: :open)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      refute has_element?(view, "[data-testid='poll-delete']")
      assert has_element?(view, "button[phx-click='request_cancel_poll']")
    end
  end

  defp open_editor(conn, poll) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    select_poll(view, poll)
    view |> element("[data-testid='poll-edit-details']") |> render_click()
    view
  end

  defp select_poll(view, poll) do
    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()
  end

  defp in_days(days), do: DateTime.add(DateTime.utc_now(:second), days, :day)

  defp local(datetime),
    do: datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)
end
