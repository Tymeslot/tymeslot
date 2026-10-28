defmodule TymeslotWeb.Dashboard.PollCustomReminderTest do
  @moduledoc """
  The reminder picker's custom row adds a typed value when focus leaves it
  (the `ReminderCustomRow` hook). A poll's picker that did not answer the
  hook's event crashed the page and lost everything typed into the poll.
  The picker shows only for a poll with invitees, so each case has one.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "reminderhost", timezone: "Etc/UTC")
    insert(:calendar_integration, user: user, is_active: true)

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  test "is added in the create form, keeping what was typed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> element("button", "New poll") |> render_click()

    view
    |> element("form[phx-submit='create_poll']")
    |> render_change(%{"poll" => %{"title" => "Board meeting", "invitees" => "ada@example.com"}})

    type_custom_reminder(view)

    assert has_element?(view, "[data-testid='poll-reminders-form']", "30 minutes before")
    assert has_element?(view, "input[name='poll[title]'][value='Board meeting']")
  end

  test "is added in the editor of an open poll", %{conn: conn, user: user} do
    poll =
      insert(:poll,
        user: user,
        status: :open,
        title: "Offsite",
        timezone: "Etc/UTC",
        meeting_type_id: nil,
        deadline_at: in_days(3)
      )

    insert(:poll_time_slot, poll: poll, start_time: in_days(7), position: 0)
    insert_invitee(poll)

    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()

    view |> element("[data-testid='poll-edit-details']") |> render_click()
    type_custom_reminder(view)

    assert has_element?(view, "[data-testid='poll-reminders-form']", "30 minutes before")
    assert has_element?(view, "[data-testid='poll-details-form']")
  end

  defp type_custom_reminder(view) do
    view |> element("[data-testid='reminder-custom-toggle']") |> render_click()

    view
    |> element("[data-testid='poll-reminders-form']")
    |> render_change(%{"reminder" => %{"value" => "30", "unit" => "minutes"}})

    view
    |> element("#poll_reminder-custom-row")
    |> render_hook("poll_commit_custom_reminder", %{
      "reminder" => %{"value" => "30", "unit" => "minutes"}
    })
  end

  defp insert_invitee(poll) do
    now = DateTime.utc_now(:second)

    insert(:poll_participant,
      poll: poll,
      invited_at: now,
      confirmed_at: now,
      link_sent_at: now,
      voted_at: nil
    )
  end

  defp in_days(days), do: DateTime.add(DateTime.utc_now(:second), days, :day)
end
