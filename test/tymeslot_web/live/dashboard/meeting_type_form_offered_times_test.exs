defmodule TymeslotWeb.Dashboard.MeetingTypeFormOfferedTimesTest do
  @moduledoc """
  A one-to-one type's offered times in the meeting-type form: adding a time
  in the host's own time zone, removing one, and group bookings held off
  while times are offered. Driven through the form's own controls.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.OfferedTimes
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks

  @form "[id^='meeting-type-form-wrapper-']"

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

  defp solo_type(user) do
    venue = insert(:venue, user: user, name: "Office")

    insert(:meeting_type,
      user: user,
      name: "Consultation",
      duration_minutes: 30,
      max_participants: 1,
      fixed_dates: true,
      locations: [in_person_location([venue])]
    )
  end

  defp future_date(days), do: Date.utc_today() |> Date.add(days) |> Date.to_iso8601()

  defp offer(view, date, time) do
    view
    |> element("input[name='offered_time[date]']")
    |> render_change(%{"offered_time" => %{"date" => date}})

    view
    |> element("input[name='offered_time[time]']")
    |> render_change(%{"offered_time" => %{"time" => time}})

    view |> element("[data-testid='add-offered-time']") |> render_click()
  end

  test "adds a time, read in the host's time zone, and lists it", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    {:ok, _profile} = Profiles.update_timezone(profile, "Asia/Tokyo")
    meeting_type = solo_type(user)
    view = edit(conn, meeting_type)

    assert has_element?(view, "[data-testid='no-offered-times']")

    date = future_date(10)
    offer(view, date, "09:30")

    assert [offered] = OfferedTimes.list(meeting_type)
    # 09:30 in Tokyo is 00:30 UTC the same day.
    assert offered.starts_at == DateTime.new!(Date.from_iso8601!(date), ~T[00:30:00])
    assert has_element?(view, "[data-testid='offered-time']")
    refute has_element?(view, "[data-testid='offered-time-error']")
  end

  test "refuses a time in the past and says why", %{conn: conn, user: user} do
    meeting_type = solo_type(user)
    view = edit(conn, meeting_type)

    offer(view, future_date(-2), "09:30")

    assert has_element?(view, "[data-testid='offered-time-error']", "future")
    assert OfferedTimes.list(meeting_type) == []
  end

  test "removes a time", %{conn: conn, user: user} do
    meeting_type = solo_type(user)
    starts_at = DateTime.add(DateTime.utc_now(:second), 5, :day)
    {:ok, _offered} = OfferedTimes.add(meeting_type, user.id, starts_at)
    view = edit(conn, meeting_type)

    view |> element("[data-testid='remove-offered-time']") |> render_click()

    assert OfferedTimes.list(meeting_type) == []
    refute has_element?(view, "[data-testid='offered-time']")
  end

  test "group bookings cannot be turned on while times are offered", %{conn: conn, user: user} do
    meeting_type = solo_type(user)
    starts_at = DateTime.add(DateTime.utc_now(:second), 5, :day)
    {:ok, _offered} = OfferedTimes.add(meeting_type, user.id, starts_at)
    view = edit(conn, meeting_type)

    assert has_element?(view, "input[phx-click='toggle_group_bookings'][disabled]")
    assert render(view) =~ "Remove the offered times"

    # A forged event changes nothing either.
    view |> with_target(@form) |> render_click("toggle_group_bookings", %{})

    assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).max_participants == 1
  end

  test "marks a time the booking rules put out of reach", %{conn: conn, user: user} do
    meeting_type = solo_type(user)
    # The default schedule's 90-day window, and its three hours' notice.
    now = DateTime.utc_now(:second)
    {:ok, _too_far} = OfferedTimes.add(meeting_type, user.id, DateTime.add(now, 120, :day))
    {:ok, _too_soon} = OfferedTimes.add(meeting_type, user.id, DateTime.add(now, 1, :hour))
    {:ok, _open} = OfferedTimes.add(meeting_type, user.id, DateTime.add(now, 5, :day))
    view = edit(conn, meeting_type)

    badges =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[data-testid='offered-time-out-of-reach']")
      |> Enum.map(&String.trim(Floki.text(&1)))

    assert badges == ["inside the minimum notice", "beyond the booking window"]
  end

  test "turning fixed dates off keeps the times, and the toggle stays free", %{
    conn: conn,
    user: user
  } do
    meeting_type = solo_type(user)
    starts_at = DateTime.add(DateTime.utc_now(:second), 5, :day)
    {:ok, _offered} = OfferedTimes.add(meeting_type, user.id, starts_at)
    view = edit(conn, meeting_type)

    refute has_element?(view, "input[phx-click='toggle_fixed_dates'][disabled]")
    view |> element("input[phx-click='toggle_fixed_dates']") |> render_click()

    refute MeetingTypes.get_meeting_type(meeting_type.id, user.id).fixed_dates
    refute has_element?(view, "[data-testid='offered-times']")
    assert [_kept] = OfferedTimes.list(meeting_type)

    # The kept times still hold group bookings off, and the host is told
    # where to find them.
    assert has_element?(view, "input[phx-click='toggle_group_bookings'][disabled]")
    assert render(view) =~ "Turn on fixed dates and remove them"
  end
end
