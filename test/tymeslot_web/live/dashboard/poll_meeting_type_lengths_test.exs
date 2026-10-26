defmodule TymeslotWeb.Dashboard.PollMeetingTypeLengthsTest do
  @moduledoc """
  The poll create form's duration for a meeting type that offers several
  lengths: the host picks one of them, and the poll and its times take it.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "lengthshost", timezone: "Etc/UTC")
    insert(:calendar_integration, user: user, is_active: true)

    several =
      insert(:meeting_type,
        user: user,
        name: "Workshop",
        duration_minutes: 30,
        extra_lengths_minutes: [60, 90]
      )

    one = insert(:meeting_type, user: user, name: "Call", duration_minutes: 45)

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user, several: several, one: one}
  end

  defp open_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    view |> element("button", "New poll") |> render_click()
    view |> element("button", "Add time") |> render_click()
    view
  end

  defp change(view, poll_params) do
    view
    |> element("form[phx-submit='create_poll']")
    |> render_change(%{"poll" => poll_params})
  end

  defp submit(view, poll_params) do
    date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

    view
    |> form("form[phx-submit='create_poll']", %{
      "poll" =>
        Map.merge(
          %{"title" => "Planning", "timezone" => "Etc/UTC", "slots" => %{"0" => "#{date}T09:00"}},
          poll_params
        )
    })
    |> render_submit()
  end

  test "a type with several lengths offers them, and the poll takes the one chosen",
       %{conn: conn, user: user, several: several} do
    view = open_form(conn)
    change(view, %{"meeting_type_id" => to_string(several.id)})

    assert has_element?(view, "[data-testid='poll-duration-select'] option[value='30'][selected]")
    assert has_element?(view, "[data-testid='poll-duration-select'] option[value='60']")
    assert has_element?(view, "[data-testid='poll-duration-select'] option[value='90']")

    change(view, %{"meeting_type_id" => to_string(several.id), "duration" => "60"})
    submit(view, %{"meeting_type_id" => to_string(several.id), "duration" => "60"})

    assert [poll] = Polls.list_polls(user.id)
    assert poll.duration_minutes == 60
    assert [slot] = poll.time_slots
    assert DateTime.diff(slot.end_time, slot.start_time, :minute) == 60
  end

  test "a type with one length keeps it, with nothing to choose",
       %{conn: conn, user: user, one: one} do
    view = open_form(conn)
    html = change(view, %{"meeting_type_id" => to_string(one.id)})

    refute has_element?(view, "[data-testid='poll-duration-select']")
    assert html =~ "Duration: 45 min (from meeting type)"

    submit(view, %{"meeting_type_id" => to_string(one.id)})

    assert [poll] = Polls.list_polls(user.id)
    assert poll.duration_minutes == 45
  end

  test "switching to a type that does not offer the chosen length takes its own",
       %{conn: conn, several: several, one: one} do
    view = open_form(conn)
    change(view, %{"meeting_type_id" => to_string(several.id), "duration" => "90"})
    html = change(view, %{"meeting_type_id" => to_string(one.id), "duration" => "90"})

    assert html =~ "Duration: 45 min (from meeting type)"
  end
end
