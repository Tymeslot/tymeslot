defmodule TymeslotWeb.Live.Themes.ThemeIntegrationTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @moduledoc """
  Tests that themes actually work for booking meetings.
  These tests verify production readiness of themes.
  """

  describe "theme booking flow" do
    setup tags do
      Mox.set_mox_from_context(tags)
      TestMocks.setup_calendar_mocks()

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

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      # Core requirement: visitors must see meeting types
      assert html =~ meeting_type.name, "Theme must show meeting types"
    end

    test "visitor can see meeting types with rhythm theme", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type
    } do
      {:ok, _result} = update_theme(profile, "2")

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      # Theme loads with the booking interface, same core requirement as Quill
      assert html =~ meeting_type.name, "Theme must show meeting types"
    end
  end

  describe "theme error handling" do
    setup tags do
      Mox.set_mox_from_context(tags)
      TestMocks.setup_calendar_mocks()
      :ok
    end

    for {theme_name, theme_id} <- [{"quill", "1"}, {"rhythm", "2"}] do
      test "#{theme_name} shows the empty state, not phantom durations, when the host has no meeting types",
           %{conn: conn} do
        user = insert(:user)

        profile =
          insert(:profile,
            user: user,
            username: "emptyuser-#{unquote(theme_id)}",
            booking_theme: unquote(theme_id)
          )

        # Add calendar integration to pass readiness check
        insert(:calendar_integration, user: user, is_active: true)

        {:ok, view, html} = live(conn, ~p"/#{profile.username}")

        # Should not crash, should show something
        assert html =~ profile.username

        # No bookable duration may be offered: the host has none.
        refute has_element?(view, "[data-testid='duration-option']")
        refute html =~ "15-minutes"
        refute html =~ "30-minutes"
        assert html =~ "No meeting types available"
      end
    end

    test "a booking page view does not seed default meeting types for the host", %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "unseeded", booking_theme: "1")
      insert(:calendar_integration, user: user, is_active: true)

      {:ok, _view, _html} = live(conn, ~p"/#{profile.username}")

      refute MeetingTypeQueries.has_meeting_types?(user.id)
    end

    test "invalid theme falls back gracefully", %{conn: conn} do
      user = insert(:user)

      profile =
        insert(:profile, user: user, username: "testuser", booking_theme: "999")

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      # An unknown theme id falls back to Quill's stylesheet.
      assert html =~ "scheduling-theme-quill.css"
      refute html =~ "scheduling-theme-rhythm.css"
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
