defmodule TymeslotWeb.Dashboard.MeetingTypeFormGroupBookingsTest do
  @moduledoc """
  LiveView coverage for the meeting-type form's Group bookings section —
  the user journey where an organiser lets multiple people book the same
  slot and sets the participant limit.

  Edit mode auto-saves every change; create mode serialises the toggle and
  limit through hidden inputs. Group bookings and payments are mutually
  exclusive (covered in the dedicated describe below).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  describe "Editing: auto-save" do
    test "toggling group bookings on persists the default limit and the input persists changes",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Team Demo")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      assert render(view) =~ "Participant limit"

      updated = reload_type(user, meeting_type.id)
      assert updated.max_participants == 10

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "25"}})

      assert reload_type(user, meeting_type.id).max_participants == 25
    end

    test "toggling group bookings off reverts the limit to 1", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, max_participants: 8)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      # Stored group type pre-fills the toggle on and the input with 8.
      assert has_element?(view, "input[phx-click='toggle_group_bookings'][checked]")
      assert render(view) =~ ~s(value="8")

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      assert reload_type(user, meeting_type.id).max_participants == 1
    end

    test "a limit above 999 shows an inline error and does not persist",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "1500"}})

      assert render(view) =~ "Participant limit cannot exceed 999"
      assert reload_type(user, meeting_type.id).max_participants == 10
    end
  end

  describe "Creating" do
    test "the hidden fields persist the limit on submit", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

      # Remove the default reminder so the hidden reminder inputs do not
      # break Plug.Conn.Query re-encoding on submit (same workaround the
      # payments create test uses).
      view |> element("button[aria-label='Remove reminder']") |> render_click()

      view
      |> element("input[phx-click='toggle_group_bookings']")
      |> render_click()

      view
      |> element("input[phx-change='change_max_participants']")
      |> render_change(%{"meeting_type" => %{"max_participants_input" => "12"}})

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{
          "name" => "Group Workshop",
          "duration" => "60"
        }
      })
      |> render_submit()

      assert render(view) =~ "Meeting type created"

      created =
        Enum.find(
          MeetingTypes.get_all_meeting_types(user.id),
          &(&1.name == "Group Workshop")
        )

      assert created.max_participants == 12
    end
  end

  defp reload_type(user, id) do
    Enum.find(MeetingTypes.get_all_meeting_types(user.id), &(&1.id == id))
  end
end
