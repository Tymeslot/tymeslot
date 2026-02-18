defmodule TymeslotWeb.Live.Themes.ThemeIntegrationTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.TestMocks

  @moduledoc """
  @moduletag :utils
  Tests that themes actually work for booking meetings.
  These tests verify production readiness of themes.
  """

  describe "theme booking flow" do
    setup tags do
      Mox.set_mox_from_context(tags)
      TestMocks.setup_all_mocks()

      # Create a user with meeting types
      user = insert(:user)
      profile = insert(:profile, user: user, username: "testuser")

      # Add calendar integration to pass readiness check
      insert(:calendar_integration, user: user, is_active: true)

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Quick Chat",
          duration_minutes: 30
        )

      %{profile: profile, meeting_type: meeting_type}
    end

    test "visitor can see meeting types with quill theme", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type
    } do
      {:ok, _result} = update_theme(profile, "1")

      {:ok, view, html} = live(conn, ~p"/#{profile.username}")

      # Core requirement: visitors must see meeting types
      assert html =~ meeting_type.name, "Theme must show meeting types"
      assert view
    end

    test "visitor can see meeting types with rhythm theme", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type
    } do
      {:ok, _result} = update_theme(profile, "2")

      {:ok, view, html} = live(conn, ~p"/#{profile.username}")

      # Theme loads with booking interface
      assert html =~ profile.username or html =~ meeting_type.name
      assert view
    end
  end

  describe "theme error handling" do
    setup tags do
      Mox.set_mox_from_context(tags)
      TestMocks.setup_all_mocks()
      :ok
    end

    test "themes handle no meeting types", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "emptyuser", booking_theme: "1")

      # Add calendar integration to pass readiness check
      insert(:calendar_integration, user: user, is_active: true)

      {:ok, view, html} = live(conn, ~p"/#{profile.username}")

      # Should not crash, should show something
      assert view
      assert html =~ profile.username or has_element?(view, "[data-testid='duration-option']")
    end

    test "invalid theme falls back gracefully", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "testuser", booking_theme: "999")

      # Should not crash
      assert {:ok, _view, _html} = live(conn, ~p"/#{profile.username}")
    end

    test "shows readiness error when no calendar integration is connected", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "no-calendar", booking_theme: "1")

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      # Check for the error message (HTML entities will be escaped)
      assert html =~ "organizer hasn"
      assert html =~ "connected a calendar yet"
    end
  end

  # Helper
  defp update_theme(profile, theme_id) do
    Repo.update(Changeset.change(profile, %{booking_theme: theme_id}))
  end
end
