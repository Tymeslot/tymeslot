defmodule TymeslotWeb.Dashboard.ProfileSettingsTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :profiles
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Repo

  alias Ecto.Changeset
  alias Tymeslot.Utils.TimezoneUtils

  setup :setup_dashboard_user

  describe "Avatar upload" do
    test "successfully uploads an avatar", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Prepare file for upload with valid PNG magic bytes
      png_content =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0,
          0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

      avatar = %{
        last_modified: System.system_time(:millisecond),
        name: "avatar.png",
        content: png_content,
        type: "image/png"
      }

      # Simulate selecting a file
      view
      |> file_input("#avatar-upload-form", :avatar, [avatar])
      |> render_upload("avatar.png")

      # We wait for the message processing (auto-consumption)
      render(view)

      # Verify success message appears without manual submit
      assert render(view) =~ "Avatar updated successfully"

      # Verify profile was updated in DB
      updated_profile = Repo.reload!(profile)
      assert updated_profile.avatar != nil
    end

    test "does not show error when no files are provided on submit (auto-upload fallback)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Submit without any file selected
      view
      |> form("#avatar-upload-form", %{})
      |> render_submit()

      # Wait for message processing
      render(view)

      # Should NOT show "No file was uploaded" anymore as we silently ignore empty results
      refute render(view) =~ "No file was uploaded"
    end

    test "fails with invalid file type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      avatar = %{
        last_modified: System.system_time(:millisecond),
        name: "test.txt",
        content: "text content",
        type: "text/plain"
      }

      view
      |> file_input("#avatar-upload-form", :avatar, [avatar])
      |> render_upload("test.txt")

      render(view)

      # Should show the humanized error message from LiveView's extension validation
      assert render(view) =~ "Not accepted"
    end

    test "successfully deletes an avatar", %{conn: conn, profile: profile} do
      # Manually set an avatar for the profile to test deletion
      profile = Repo.update!(Changeset.change(profile, avatar: "test_avatar.png"))

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Verify the delete button is visible
      assert has_element?(view, "button", "Delete Photo")

      # Click the show modal button
      view
      |> element("button", "Delete Photo")
      |> render_click()

      # Click the confirm delete button in the modal
      view
      |> element("button", "Delete Avatar")
      |> render_click()

      # Verify success message
      assert render(view) =~ "Avatar deleted successfully"

      # Verify profile was updated in DB
      updated_profile = Repo.reload!(profile)
      assert updated_profile.avatar == nil
    end
  end

  describe "Display Name updates" do
    test "successfully updates display name on change", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#display-name-form", %{full_name: "New Display Name"})
      |> render_change()

      assert render(view) =~ "Display name updated"

      updated_profile = Repo.reload!(profile)
      assert updated_profile.full_name == "New Display Name"
    end

    test "shows error for invalid display name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Assuming too long name is invalid
      long_name = String.duplicate("a", 101)

      view
      |> form("#display-name-form", %{full_name: long_name})
      |> render_change()

      assert render(view) =~ "too long"
    end

    test "does not flash when display name is unchanged", %{conn: conn, profile: profile} do
      # Set a known name first
      profile = Repo.update!(Changeset.change(profile, full_name: "Existing Name"))

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Trigger change with the same value that's already in the DB
      view
      |> form("#display-name-form", %{full_name: profile.full_name})
      |> render_change()

      refute render(view) =~ "Display name updated"
    end

    test "clears display name when empty string is entered", %{conn: conn, profile: profile} do
      profile = Repo.update!(Changeset.change(profile, full_name: "Some Name"))

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#display-name-form", %{full_name: ""})
      |> render_change()

      # Empty string is treated as a valid clear — no error, name is nil in DB
      # Ecto's :string type coerces "" to nil on cast, so nil is the persisted value.
      updated_profile = Repo.reload!(profile)
      assert is_nil(updated_profile.full_name)
    end
  end

  describe "Username updates" do
    test "successfully updates username", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#username-form-container form", %{username: "new-username"})
      |> render_submit()

      assert render(view) =~ "Username updated"

      updated_profile = Repo.reload!(profile)
      assert updated_profile.username == "new-username"
    end

    test "checks username availability", %{conn: conn} do
      insert(:profile, username: "taken-username")
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Check availability
      view
      |> form("#username-form-container form", %{username: "taken-username"})
      |> render_change()

      assert render(view) =~ "Taken"

      view
      |> form("#username-form-container form", %{username: "available-username"})
      |> render_change()

      assert render(view) =~ "Available"
    end

    test "shows error for invalid username format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#username-form-container form", %{username: "Invalid Username!"})
      |> render_change()

      assert render(view) =~ "Invalid"
    end

    test "shows invalid badge when reserved username is typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#username-form-container form", %{username: "admin"})
      |> render_change()

      # Reserved names are rejected by InputProcessor as invalid, not as taken
      assert render(view) =~ "Invalid"
      refute render(view) =~ "Available"
      refute render(view) =~ "Taken"
    end

    test "shows error when reserved username is submitted", %{conn: conn, profile: _profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#username-form-container form", %{username: "api"})
      |> render_submit()

      # InputProcessor.validate_field catches reserved names before Profiles.update_username
      # is reached, and surfaces the message "This username is reserved and cannot be used".
      html = render(view)
      assert html =~ "reserved"
    end

    test "shows booking URL after successful username update", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#username-form-container form", %{username: "mybookingpage"})
      |> render_submit()

      assert render(view) =~ "mybookingpage"
    end
  end

  describe "Timezone updates" do
    test "opens and closes the timezone dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Dropdown should be closed initially — search input not visible
      refute render(view) =~ "Search cities"

      # Open it
      view
      |> element("#timezone-form-container button[phx-click='toggle_timezone_dropdown']")
      |> render_click()

      assert render(view) =~ "Search cities"

      # Close it via toggle
      view
      |> element("#timezone-form-container button[phx-click='toggle_timezone_dropdown']")
      |> render_click()

      refute render(view) =~ "Search cities"
    end

    test "filters timezone options by search term", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Open the dropdown
      view
      |> element("#timezone-form-container button[phx-click='toggle_timezone_dropdown']")
      |> render_click()

      # The search input uses phx-keyup; send the event with the "value" key that the
      # component expects (name="value" on the input).
      view
      |> element("#timezone-search")
      |> render_keyup(%{value: "London"})

      html = render(view)
      assert html =~ "London"
      refute html =~ "New York"
    end

    test "successfully updates timezone", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Open dropdown
      view
      |> element("#timezone-form-container button[phx-click='toggle_timezone_dropdown']")
      |> render_click()

      # Verify search input is visible (means dropdown is open)
      assert render(view) =~ "Search cities"

      # Click the New York option
      # We use element with text to be sure
      view |> element("[phx-click='change_timezone']", "New York") |> render_click()

      expected_label = TimezoneUtils.format_timezone("America/New_York")
      assert render(view) =~ "Timezone updated to #{expected_label}"

      updated_profile = Repo.reload!(profile)
      assert updated_profile.timezone == "America/New_York"
    end

    test "shows error for invalid timezone format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # Open dropdown to ensure options are in DOM
      view
      |> element("#timezone-form-container button[phx-click='toggle_timezone_dropdown']")
      |> render_click()

      # Click an option but override with an invalid timezone value
      # We use a text filter to pick a specific element from the list
      view
      |> element("#timezone-form-container [phx-click='change_timezone']", "Adak, Alaska")
      |> render_click(%{timezone: "Invalid-Timezone-Format"})

      assert render(view) =~ "Invalid timezone format"
    end
  end
end
