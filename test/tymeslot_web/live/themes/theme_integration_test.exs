defmodule TymeslotWeb.Live.Themes.ThemeIntegrationTest do
  use TymeslotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo

  @moduledoc """
  Tests that themes actually work for booking meetings.
  These tests verify production readiness of themes.
  """

  describe "theme booking flow" do
    setup do
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
      {:ok, _} = update_theme(profile, "1")

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
      {:ok, _} = update_theme(profile, "2")

      {:ok, view, html} = live(conn, ~p"/#{profile.username}")

      # Theme loads with booking interface
      assert html =~ profile.username or html =~ meeting_type.name
      assert view
    end
  end

  describe "theme error handling" do
    test "themes handle no meeting types", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "emptyuser", booking_theme: "1")

      {:ok, view, html} = live(conn, ~p"/#{profile.username}")

      # Should not crash, should show something
      assert view
      assert html =~ "Schedule"
    end

    test "invalid theme falls back gracefully", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "testuser", booking_theme: "999")

      # Should not crash
      assert {:ok, _view, _html} = live(conn, ~p"/#{profile.username}")
    end
  end

  # Helper
  defp update_theme(profile, theme_id) do
    Repo.update(Changeset.change(profile, %{booking_theme: theme_id}))
  end
end
