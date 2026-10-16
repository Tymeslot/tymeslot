defmodule TymeslotWeb.Dashboard.MeetingTypeFormFixedDatesTest do
  @moduledoc """
  Fixed dates in the meeting-type form: turning them on for a group type,
  planning dates and cancelling them, driven through the form's own
  controls.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :setup_dashboard_user

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  defp edit(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view |> element("#meeting-type-form-tabs-tab-booking") |> render_click()
    view
  end

  defp group_type(user, attrs \\ []) do
    venue = insert(:venue, user: user, name: "Main Hall")

    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: user,
          name: "Introduction to X",
          duration_minutes: 90,
          max_participants: 10,
          locations: [in_person_location([venue])]
        ],
        attrs
      )
    )
  end

  defp reload(meeting_type),
    do: MeetingTypes.get_meeting_type(meeting_type.id, meeting_type.user_id)

  defp future_date(days), do: Date.utc_today() |> Date.add(days) |> Date.to_iso8601()

  defp plan(view, date, time, closes_at \\ "") do
    view
    |> element("input[name='session[date]']")
    |> render_change(%{"session" => %{"date" => date}})

    view
    |> element("input[name='session[time]']")
    |> render_change(%{"session" => %{"time" => time}})

    view
    |> element("input[name='session[closes_at]']")
    |> render_change(%{"session" => %{"closes_at" => closes_at}})

    view |> element("[data-testid='add-session']") |> render_click()
  end

  test "turning fixed dates on is stored, and the planning row appears", %{
    conn: conn,
    user: user
  } do
    meeting_type = group_type(user)
    view = edit(conn, meeting_type)

    refute has_element?(view, "[data-testid='new-session']")

    view |> element("input[phx-click='toggle_fixed_dates']") |> render_click()

    assert reload(meeting_type).fixed_dates
    assert has_element?(view, "[data-testid='no-sessions']")
    assert has_element?(view, "[data-testid='new-session']")
  end

  test "is not offered on a one-to-one type", %{conn: conn, user: user} do
    meeting_type = group_type(user, max_participants: 1)
    view = edit(conn, meeting_type)

    refute has_element?(view, "[data-testid='fixed-dates-section']")
  end

  test "plans a date, which is listed and booked on the host's calendar", %{
    conn: conn,
    user: user
  } do
    meeting_type = group_type(user, fixed_dates: true)
    view = edit(conn, meeting_type)

    date = future_date(10)
    plan(view, date, "18:00", "#{future_date(8)}T12:00")

    assert [session] = PlannedSessions.list(meeting_type)
    assert session.planned
    assert Date.to_iso8601(DateTime.to_date(session.start_time)) == date
    assert session.registration_closes_at

    assert has_element?(view, "[data-testid='planned-session']", "0 of 10 seats taken")
    refute has_element?(view, "[data-testid='session-error']")
  end

  test "refuses a date in the past and says why", %{conn: conn, user: user} do
    meeting_type = group_type(user, fixed_dates: true)
    view = edit(conn, meeting_type)

    plan(view, Date.to_iso8601(Date.add(Date.utc_today(), -2)), "18:00")

    assert has_element?(view, "[data-testid='session-error']", "future")
    assert PlannedSessions.list(meeting_type) == []
  end

  test "cancels a date nobody booked at once", %{conn: conn, user: user} do
    meeting_type = group_type(user, fixed_dates: true)
    starts_at = Date.utc_today() |> Date.add(10) |> DateTime.new!(~T[18:00:00], "Etc/UTC")
    {:ok, session} = PlannedSessions.add(meeting_type, starts_at)
    view = edit(conn, meeting_type)

    view |> element("[data-testid='remove-session']") |> render_click()

    assert Repo.get!(MeetingSchema, session.id).status == "cancelled"
    refute has_element?(view, "[data-testid='planned-session']")
  end

  test "asks before cancelling a date people booked", %{conn: conn, user: user} do
    meeting_type = group_type(user, fixed_dates: true)
    starts_at = Date.utc_today() |> Date.add(10) |> DateTime.new!(~T[18:00:00], "Etc/UTC")
    {:ok, session} = PlannedSessions.add(meeting_type, starts_at)

    {:ok, _seat} =
      Create.execute(
        %{
          date: DateTime.to_date(starts_at),
          time: "18:00",
          duration: "90min",
          user_timezone: "Etc/UTC",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        },
        %{"name" => "Booker", "email" => "booker@example.com"}
      )

    view = edit(conn, meeting_type)

    assert has_element?(view, "[data-testid='planned-session']", "1 of 10 seats taken")

    # The toggle cannot be turned off while the date is planned.
    assert has_element?(view, "input[phx-click='toggle_fixed_dates'][disabled]")

    view |> element("[data-testid='remove-session']") |> render_click()

    assert Repo.get!(MeetingSchema, session.id).status == "confirmed"
    assert render(view) =~ "1 person is booked and will be told"

    view |> element("[data-testid='confirm-cancel-session']") |> render_click()

    assert Repo.get!(MeetingSchema, session.id).status == "cancelled"
  end
end
