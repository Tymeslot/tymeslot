defmodule TymeslotWeb.Dashboard.MeetingSettingsTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
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

      # Editing a field auto-saves immediately — there is no submit button.
      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => "Renamed Type"}})

      # Persisted before any "Done"/close action: nothing depends on it.
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).name == "Renamed Type"
      assert render(view) =~ "All changes saved"

      # Done only tears down the overlay; the list reflects the saved state.
      view |> element("button", "Done") |> render_click()

      html = render(view)
      assert html =~ "Renamed Type"
      refute html =~ "Old Name"
    end
  end

  # ===========================================================================
  # Edit form tabs
  # ===========================================================================

  describe "Edit form tabs" do
    setup %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Tabbed Type", duration_minutes: 30)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      %{view: view, meeting_type: meeting_type}
    end

    test "opens on the Details tab with the other panels hidden", %{view: view} do
      assert has_element?(view, "[role='tablist']")
      assert has_element?(view, "#tab-details[aria-selected='true']")

      refute has_element?(view, "#panel-details[hidden]")
      assert has_element?(view, "#panel-location[hidden]")
      assert has_element?(view, "#panel-booking[hidden]")
      assert has_element?(view, "#panel-questions[hidden]")
      assert has_element?(view, "#panel-reminders[hidden]")
    end

    test "switching tabs reveals that panel and hides the previous one", %{view: view} do
      view |> element("#tab-booking") |> render_click()

      assert has_element?(view, "#tab-booking[aria-selected='true']")
      assert has_element?(view, "#tab-details[aria-selected='false']")
      refute has_element?(view, "#panel-booking[hidden]")
      assert has_element?(view, "#panel-details[hidden]")
    end

    test "an invalid field marks its tab with an error indicator", %{view: view} do
      view |> element("#tab-reminders") |> render_click()

      # The name input sits in the now-hidden Details panel; an invalid value
      # must still surface there via the tab indicator.
      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => ""}})

      assert has_element?(view, "#tab-details span", "This tab contains errors")
      refute has_element?(view, "#tab-reminders span", "This tab contains errors")
    end

    test "the visibility toggle lives in the Booking Rules panel and persists", %{
      view: view,
      meeting_type: meeting_type,
      user: user
    } do
      view |> element("#tab-booking") |> render_click()

      view
      |> element("#panel-booking [phx-click='toggle_private']")
      |> render_click()

      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).is_private
    end

    test "create mode renders all sections stacked without a tab bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view |> element("button", "Add Meeting Type") |> render_click()

      refute has_element?(view, "[role='tablist']")

      for panel <- ~w(details location booking questions reminders) do
        assert has_element?(view, "#panel-#{panel}")
        refute has_element?(view, "#panel-#{panel}[hidden]")
      end

      # The visibility switch needs an existing type; it must not render here.
      refute has_element?(view, "#panel-booking [phx-click='toggle_private']")
    end
  end

  # ===========================================================================
  # Auto-saving edits
  # ===========================================================================

  describe "Auto-saving edits" do
    test "changing a field persists immediately without a submit", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element(~s|input[name="meeting_type[duration]"]|)
      |> render_change(%{"meeting_type" => %{"duration" => "45"}})

      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).duration_minutes == 45
      assert render(view) =~ "All changes saved"
    end

    test "an invalid change is not persisted and is flagged unsaved", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Keep Me")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      html =
        view
        |> element(~s|input[name="meeting_type[name]"]|)
        |> render_change(%{"meeting_type" => %{"name" => ""}})

      # The last valid value stays in the database; the editor flags it unsaved.
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).name == "Keep Me"
      assert html =~ "Unsaved changes"
    end

    test "a name collision with another meeting type is not persisted and shows the error indicator",
         %{conn: conn, user: user} do
      # Insert two meeting types for the same user; we will try to rename type_b
      # to the name already taken by type_a. The DB unique constraint on
      # (user_id, name) turns this into a genuine changeset error — not one of
      # the :incomplete companion-field cases — so apply_result/2 must set
      # save_status: :error.
      _type_a = insert(:meeting_type, user: user, name: "Taken Name")
      type_b = insert(:meeting_type, user: user, name: "Original Name")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{type_b.id}']")
      |> render_click()

      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => "Taken Name"}})

      # The original name must be intact in the database.
      assert MeetingTypes.get_meeting_type(type_b.id, user.id).name == "Original Name"

      # The editor must show the error indicator, not the success or incomplete
      # copy. HEEx escapes the apostrophe, so match the rendered entity form.
      assert render(view) =~ "Couldn&#39;t save changes"
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
      assert %{name: "Stays Around"} = MeetingTypes.get_meeting_type(meeting_type.id, user.id)
    end
  end

  # ===========================================================================
  # Booking link & visibility
  # ===========================================================================

  describe "Booking link and visibility" do
    setup %{profile: profile} do
      # The link/visibility controls only appear once the profile has a username.
      %{profile: Repo.update!(Changeset.change(profile, username: "linkhost"))}
    end

    test "toggling a type private persists the flag and badges it unlisted", %{
      conn: conn,
      user: user
    } do
      meeting_type =
        insert(:meeting_type, user: user, name: "Strategy Session", is_private: false)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element("[phx-click='toggle_private'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      assert render(view) =~ "Visibility updated"
      assert Repo.reload!(meeting_type).is_private == true

      # The list view marks the now-private type as unlisted.
      view |> element("button", "Done") |> render_click()
      assert render(view) =~ "Unlisted"
    end

    test "changing the booking link persists the new slug after confirmation", %{
      conn: conn,
      user: user
    } do
      meeting_type = insert(:meeting_type, user: user, name: "Strategy Session")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view |> element("[phx-click='open_slug_modal']") |> render_click()

      view
      |> form("#booking-link-modal form", %{"slug" => "vip-call"})
      |> render_change()

      view |> element("#booking-link-modal button", "Save link") |> render_click()

      assert render(view) =~ "Booking link updated"
      assert Repo.reload!(meeting_type).slug == "vip-call"
    end

    test "randomising mints an unguessable link different from the name slug", %{
      conn: conn,
      user: user
    } do
      meeting_type = insert(:meeting_type, user: user, name: "Strategy Session")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view |> element("[phx-click='open_slug_modal']") |> render_click()
      view |> element("#booking-link-modal [phx-click='randomise_slug']") |> render_click()
      view |> element("#booking-link-modal button", "Save link") |> render_click()

      assert render(view) =~ "Booking link updated"
      reloaded = Repo.reload!(meeting_type)
      assert reloaded.slug
      assert reloaded.slug != "strategy-session"
    end

    test "a booking link already taken by another type is rejected", %{conn: conn, user: user} do
      _taken = insert(:meeting_type, user: user, name: "Coffee Chat")
      other = insert(:meeting_type, user: user, name: "Other Session")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{other.id}']")
      |> render_click()

      view |> element("[phx-click='open_slug_modal']") |> render_click()

      view
      |> form("#booking-link-modal form", %{"slug" => "coffee-chat"})
      |> render_change()

      view |> element("#booking-link-modal button", "Save link") |> render_click()

      assert render(view) =~ "already taken"
      assert Repo.reload!(other).slug == nil
    end
  end
end
