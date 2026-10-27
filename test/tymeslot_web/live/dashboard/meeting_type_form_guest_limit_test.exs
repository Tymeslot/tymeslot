defmodule TymeslotWeb.Dashboard.MeetingTypeFormGuestLimitTest do
  @moduledoc """
  The meeting-type form's limit on the guests one booking may bring, driven
  through the form's own controls, and the note on a group type that guests
  take seats.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  defp edit(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view |> element("#meeting-type-form-tabs-tab-booking") |> render_click()
    view
  end

  defp insert_type(user, attrs) do
    venue = insert(:venue, user: user)
    insert(:meeting_type, [user: user, locations: [in_person_location([venue])]] ++ attrs)
  end

  defp reload(user, id), do: MeetingTypes.get_meeting_type(id, user.id)

  test "limits the guests per booking, and takes the limit off again", %{conn: conn, user: user} do
    meeting_type = insert_type(user, allow_guests: true)
    view = edit(conn, meeting_type)

    view |> element("input[phx-click='toggle_guest_limit']") |> render_click()
    assert reload(user, meeting_type.id).max_guests_per_booking == 1

    view
    |> element("input[phx-change='change_guest_limit']")
    |> render_change(%{"meeting_type" => %{"guest_limit_input" => "3"}})

    assert reload(user, meeting_type.id).max_guests_per_booking == 3
    assert render(view) =~ "up to 3 guests"

    view |> element("input[phx-click='toggle_guest_limit']") |> render_click()
    assert reload(user, meeting_type.id).max_guests_per_booking == nil
  end

  test "clamps a limit outside its range", %{conn: conn, user: user} do
    meeting_type = insert_type(user, allow_guests: true, max_guests_per_booking: 2)
    view = edit(conn, meeting_type)

    view
    |> element("input[phx-change='change_guest_limit']")
    |> render_change(%{"meeting_type" => %{"guest_limit_input" => "50"}})

    assert reload(user, meeting_type.id).max_guests_per_booking == 10
  end

  test "offers the limit only while guests are allowed", %{conn: conn, user: user} do
    view = edit(conn, insert_type(user, allow_guests: false))

    refute has_element?(view, "input[phx-click='toggle_guest_limit']")
  end

  test "says on a group type that guests take seats", %{conn: conn, user: user} do
    view = edit(conn, insert_type(user, allow_guests: true, max_participants: 10))
    assert has_element?(view, "[data-testid='guests-take-seats']")

    view = edit(conn, insert_type(user, allow_guests: true, name: "Solo talk"))
    refute has_element?(view, "[data-testid='guests-take-seats']")
  end
end
