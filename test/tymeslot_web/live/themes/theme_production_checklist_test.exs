defmodule TymeslotWeb.Live.Themes.ThemeProductionChecklistTest do
  use TymeslotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Themes.Registry

  @moduledoc """
  Production readiness checklist for themes.
  Run this for any new theme before releasing to production.

  To test a new theme, add it to @themes_to_test.
  """

  # Use registry to get all active theme IDs
  @themes_to_test Registry.valid_theme_ids()

  describe "production readiness checklist" do
    for theme_id <- @themes_to_test do
      @tag theme: theme_id
      test "theme #{theme_id} displays meeting types", %{conn: conn} do
        # Setup user with meeting types
        user = insert(:user, name: "Test User")

        profile =
          insert(:profile,
            user: nil,
            user_id: user.id,
            username: "theme#{unquote(theme_id)}test",
            booking_theme: unquote(theme_id)
          )

        # Add calendar integration to pass readiness check
        insert(:calendar_integration, user: nil, user_id: user.id, is_active: true)

        mt1 = insert(:meeting_type, user: nil, user_id: user.id, name: "Quick Call")
        mt2 = insert(:meeting_type, user: nil, user_id: user.id, name: "Consultation")

        # Load page
        {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

        # Must show meeting types
        assert html =~ mt1.name, "Theme #{unquote(theme_id)} must show meeting type: #{mt1.name}"
        assert html =~ mt2.name, "Theme #{unquote(theme_id)} must show meeting type: #{mt2.name}"
      end

      @tag theme: theme_id
      test "theme #{theme_id} handles edge cases", %{conn: conn} do
        # No meeting types
        user1 = insert(:user)

        profile1 =
          insert(:profile,
            user: nil,
            user_id: user1.id,
            username: "empty#{unquote(theme_id)}",
            booking_theme: unquote(theme_id)
          )

        {:ok, view1, _html} = live(conn, ~p"/#{profile1.username}")
        assert view1, "Theme must handle users with no meeting types"

        # Very long meeting name
        user2 = insert(:user)

        profile2 =
          insert(:profile,
            user: nil,
            user_id: user2.id,
            username: "long#{unquote(theme_id)}",
            booking_theme: unquote(theme_id)
          )

        insert(:meeting_type,
          user: nil,
          user_id: user2.id,
          name:
            "This is an extremely long meeting type name that could potentially break layouts if the theme doesn't handle text overflow properly"
        )

        {:ok, view2, _html} = live(conn, ~p"/#{profile2.username}")
        assert view2, "Theme must handle very long meeting names"
      end

      @tag theme: theme_id
      test "theme #{theme_id} is mobile ready", %{conn: conn} do
        user = insert(:user)

        profile =
          insert(:profile,
            user: nil,
            user_id: user.id,
            username: "mobile#{unquote(theme_id)}",
            booking_theme: unquote(theme_id)
          )

        {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

        # Basic mobile check
        assert html =~ "viewport", "Theme must include viewport meta tag for mobile"
      end
    end
  end
end
