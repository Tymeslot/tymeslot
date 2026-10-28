defmodule TymeslotWeb.Dashboard.MeetingTypeFormGroupLengthsTest do
  @moduledoc """
  Group bookings and further lengths exclude each other in the meeting-type
  form: everyone in a group slot shares one meeting, so its length cannot be
  each booker's choice.

  Each control that would break the rule renders disabled or absent, with the
  reason; the tests also drive the refused event directly, since a stale or
  forged event must not get past the server-side guard either.
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

    view
  end

  defp form_wrapper(meeting_type),
    do: "#meeting-type-form-wrapper-meeting-type-form-edit-#{meeting_type.id}"

  defp at_venue(user) do
    venue = insert(:venue, user: user, name: "Main Hall")
    [in_person_location([venue])]
  end

  defp reload(meeting_type),
    do: MeetingTypes.get_meeting_type(meeting_type.id, meeting_type.user_id)

  test "further lengths disable the group toggle with the reason, and refuse the event",
       %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        extra_lengths_minutes: [60],
        locations: at_venue(user)
      )

    view = edit(conn, meeting_type)

    assert has_element?(view, "input[phx-click='toggle_group_bookings'][disabled]")
    assert render(view) =~ "Remove the additional durations to enable group bookings."

    view
    |> with_target(form_wrapper(meeting_type))
    |> render_click("toggle_group_bookings", %{})

    assert reload(meeting_type).max_participants == 1
  end

  test "removing the further lengths makes group bookings available again",
       %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        extra_lengths_minutes: [60],
        locations: at_venue(user)
      )

    view = edit(conn, meeting_type)

    view |> element("[data-testid='remove-length']") |> render_click()
    view |> element("input[phx-click='toggle_group_bookings']") |> render_click()

    assert %{extra_lengths_minutes: [], max_participants: 10} = reload(meeting_type)
  end

  test "a group type offers no further length, and refuses the event",
       %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type, user: user, max_participants: 5, locations: at_venue(user))

    view = edit(conn, meeting_type)

    refute has_element?(view, "[data-testid='add-length']")
    assert render(view) =~ "A group meeting type offers a single duration."

    view
    |> with_target(form_wrapper(meeting_type))
    |> render_click("add_length", %{})

    refute has_element?(view, "[data-testid='extra-length']")
    assert reload(meeting_type).extra_lengths_minutes in [nil, []]
  end
end
