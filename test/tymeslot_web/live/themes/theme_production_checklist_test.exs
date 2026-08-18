defmodule TymeslotWeb.Live.Themes.ThemeProductionChecklistTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.TestMocks
  alias Tymeslot.Themes.Catalog

  @moduledoc """
  Production readiness checklist for themes.
  Run this for any new theme before releasing to production.

  To test a new theme, add it to @themes_to_test.
  """

  # Use the catalog to get all theme IDs
  @themes_to_test Catalog.valid_ids()

  describe "production readiness checklist" do
    setup tags do
      Mox.set_mox_from_context(tags)
      TestMocks.setup_calendar_mocks()
      :ok
    end

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
        user1 = insert(:user, name: "Empty Owner")

        profile1 =
          insert(:profile,
            user: nil,
            user_id: user1.id,
            username: "empty#{unquote(theme_id)}",
            booking_theme: unquote(theme_id)
          )

        # Add calendar integration to pass readiness check
        insert(:calendar_integration, user: nil, user_id: user1.id, is_active: true)

        {:ok, _view1, html1} = live(conn, ~p"/#{profile1.username}")

        # The owner's name also sits in <title>/og:title, so a body-only check
        # is what proves the visitor can still see whose page this is.
        [_head1, body1] = String.split(html1, "<body", parts: 2)

        assert body1 =~ user1.name,
               "Theme #{unquote(theme_id)} must still name the owner with no meeting types"

        refute html1 =~ "data-testid=\"duration-option\"",
               "Theme #{unquote(theme_id)} must not render duration options with no meeting types"

        # Very long meeting name
        user2 = insert(:user)

        profile2 =
          insert(:profile,
            user: nil,
            user_id: user2.id,
            username: "long#{unquote(theme_id)}",
            booking_theme: unquote(theme_id)
          )

        # Add calendar integration to pass readiness check
        insert(:calendar_integration, user: nil, user_id: user2.id, is_active: true)

        long_name =
          "This is an extremely long meeting type name that could potentially break layouts when a theme fails to handle text overflow properly"

        insert(:meeting_type, user: nil, user_id: user2.id, name: long_name)

        {:ok, _view2, html2} = live(conn, ~p"/#{profile2.username}")

        assert html2 =~ long_name,
               "Theme #{unquote(theme_id)} must render the full long meeting type name"

        assert html2 =~ "data-testid=\"duration-option\"",
               "Theme #{unquote(theme_id)} must offer the long meeting type as a duration option"
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

        # Add calendar integration to pass readiness check
        insert(:calendar_integration, user: nil, user_id: user.id, is_active: true)
        insert(:meeting_type, user: nil, user_id: user.id, name: "Test Type")

        {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

        # Without a device-width viewport the page renders at the desktop
        # fallback width on a phone, so every responsive rule is bypassed.
        assert html =~ ~s(<meta name="viewport" content="width=device-width, initial-scale=1")

        # Basic functional check for the core booking UI
        assert html =~ "data-testid=\"duration-option\""
      end
    end
  end
end
