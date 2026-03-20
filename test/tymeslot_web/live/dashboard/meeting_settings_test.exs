defmodule TymeslotWeb.Dashboard.MeetingSettingsTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo

  setup :setup_dashboard_user

  # ===========================================================================
  # Meeting Types List
  # ===========================================================================

  describe "Meeting types list" do
    test "shows meeting types when they exist", %{conn: conn, user: user} do
      insert(:meeting_type, user: user, name: "Strategy Session")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      assert render(view) =~ "Strategy Session"
    end

    test "auto-creates and shows default meeting types for a new user", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      # Default meeting types are auto-created when a user has none; the empty
      # state should therefore never be visible on first visit.
      refute render(view) =~ "No meeting types configured yet"
    end
  end

  # ===========================================================================
  # Creating a Meeting Type
  # ===========================================================================

  describe "Creating a meeting type" do
    test "creates a new meeting type and shows it in the list", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view |> element("button", "Add Meeting Type") |> render_click()

      assert render(view) =~ "Create Meeting Type"

      # Phoenix.LiveViewTest collects all hidden form inputs before submission and then
      # re-encodes them via Plug.Conn.Query.encode. The reminder_config[][value]/[][unit]
      # hidden inputs decode into a list-of-multi-key-maps which cannot be re-encoded.
      # Removing the default reminder first causes MeetingTypeForm to re-render without
      # those hidden inputs, making the subsequent form submission encodable.
      view |> element("button[aria-label='Remove reminder']") |> render_click()

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{"name" => "Quick Coffee", "duration" => "20"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Quick Coffee"
      assert html =~ "Meeting type created"

      assert Enum.any?(MeetingTypes.get_all_meeting_types(user.id), &(&1.name == "Quick Coffee"))
    end
  end

  # ===========================================================================
  # Editing a Meeting Type
  # ===========================================================================

  describe "Editing a meeting type" do
    test "renames a meeting type and shows the updated name in the list", %{
      conn: conn,
      user: user
    } do
      meeting_type =
        insert(:meeting_type, user: user, name: "Old Name", duration_minutes: 30, is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      assert render(view) =~ "Edit Meeting Type"

      # Same reminder-removal workaround as the create test (see that test for explanation).
      view |> element("button[aria-label='Remove reminder']") |> render_click()

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{"name" => "Renamed Type", "duration" => "30"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Renamed Type"
      assert html =~ "Meeting type updated"
      refute html =~ "Old Name"
    end
  end

  # ===========================================================================
  # Toggling Meeting Type Status
  # ===========================================================================

  describe "Toggling meeting type status" do
    test "deactivates an active meeting type", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='toggle_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      assert render(view) =~ "Meeting type status updated"
      assert Repo.reload!(meeting_type).is_active == false
    end

    test "reactivates an inactive meeting type", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, is_active: false)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='toggle_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      assert render(view) =~ "Meeting type status updated"
      assert Repo.reload!(meeting_type).is_active == true
    end

    test "toggling twice returns to original state", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      # First toggle: active → inactive
      view
      |> element("[phx-click='toggle_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      assert Repo.reload!(meeting_type).is_active == false

      # Second toggle: inactive → active
      view
      |> element("[phx-click='toggle_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      assert Repo.reload!(meeting_type).is_active == true
    end
  end

  # ===========================================================================
  # Deleting a Meeting Type
  # ===========================================================================

  describe "Deleting a meeting type" do
    test "requires confirmation before removing the type from the list", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "To Be Removed")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      assert render(view) =~ "To Be Removed"

      view
      |> element("[phx-click='show_delete_modal'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      assert render(view) =~ "To Be Removed"

      view
      |> element("#delete-meeting-type-modal button", "Delete Meeting Type")
      |> render_click()

      html = render(view)
      assert html =~ "Meeting type deleted"
      refute html =~ "To Be Removed"
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id) == nil
    end

    test "cancelling the delete modal leaves the type intact", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Stays Around")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='show_delete_modal'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element("#delete-meeting-type-modal button", "Cancel")
      |> render_click()

      assert render(view) =~ "Stays Around"
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id) != nil
    end
  end

  # ===========================================================================
  # Scheduling Preferences
  # ===========================================================================

  describe "Scheduling preferences" do
    test "selecting a buffer time preset updates the profile", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='update_buffer_minutes'][phx-value-buffer_minutes='15']")
      |> render_click()

      assert render(view) =~ "Buffer time updated"
      assert Repo.reload!(profile).buffer_minutes == 15
    end

    test "selecting an advance booking window preset updates the profile", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='update_advance_booking_days'][phx-value-advance_booking_days='30']")
      |> render_click()

      assert render(view) =~ "Advance booking window updated"
      assert Repo.reload!(profile).advance_booking_days == 30
    end

    test "selecting a minimum notice preset updates the profile", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='update_min_advance_hours'][phx-value-min_advance_hours='4']")
      |> render_click()

      assert render(view) =~ "Minimum booking notice updated"
      assert Repo.reload!(profile).min_advance_hours == 4
    end

    test "entering a custom buffer value outside the allowed range is rejected", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      # Enabling custom mode saves a default value; capture it before the invalid attempt
      view
      |> element("[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      persisted_value = Repo.reload!(profile).buffer_minutes

      # Now attempt an out-of-range update via form change
      view
      |> form("form[phx-change='update_buffer_minutes']", %{"buffer_minutes" => "999"})
      |> render_change()

      # The profile value must not have changed to 999
      assert Repo.reload!(profile).buffer_minutes == persisted_value

      # The user must also see an error message explaining the rejection
      assert render(view) =~ "Buffer minutes cannot exceed 120"
    end
  end
end
