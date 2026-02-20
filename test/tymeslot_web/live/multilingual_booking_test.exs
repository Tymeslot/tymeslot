defmodule TymeslotWeb.Live.MultilingualBookingTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Mox

  setup do
    # Create a user with calendar integration for booking flow
    user = insert(:user)
    profile = insert(:profile, user: user, username: "testuser")

    # Stub calendar operations to avoid Mox errors
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _integration,
                                                                _range_start,
                                                                _range_end ->
      {:ok, []}
    end)

    insert(:calendar_integration,
      user: user,
      provider: "google",
      is_active: true
    )

    insert(:meeting_type,
      user: user,
      name: "Test Meeting",
      duration_minutes: 30,
      is_active: true
    )

    {:ok, user: user, profile: profile, username: profile.username}
  end

  describe "language detection and switching" do
    test "detects language from query parameter", %{conn: conn, username: username} do
      view = start_view(conn, username, "de")

      # Verify Gettext locale is set
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
      assert render(view) =~ "data-locale=\"de\""
    end

    test "persists language selection across navigation", %{conn: conn, username: username} do
      # Start with German via query param
      # This request goes through LocalePlug which stores it in session
      conn = get(conn, "/#{username}?locale=de")
      {:ok, _view, html} = live(conn)
      assert html =~ "data-locale=\"de\""

      # Navigate again WITHOUT the locale param - should still be German from session
      # We use recycle(conn) to maintain the session/cookies
      conn = get(recycle(conn), "/#{username}")
      {:ok, _view, html} = live(conn)
      assert html =~ "data-locale=\"de\""
    end

    test "persists locale change from dropdown across navigation", %{
      conn: conn,
      username: username
    } do
      # Start in English
      {:ok, view, _html} = live(conn, "/#{username}")
      assert render(view) =~ "data-locale=\"en\""

      # Switch to German via dropdown
      view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

      # follow_redirect can take just the conn if we don't want to assert on the path
      # It returns {:ok, conn} for external redirects (which we use for locale change)
      {:ok, conn} =
        view
        |> element("button[phx-click='change_locale'][phx-value-locale='de']")
        |> render_click()
        |> follow_redirect(conn)

      {:ok, new_view, _html} = live(conn)
      assert render(new_view) =~ "data-locale=\"de\""

      # Navigate again - locale should persist in session
      conn = recycle(conn)
      {:ok, final_view, _html} = live(conn, "/#{username}")
      assert render(final_view) =~ "data-locale=\"de\""
    end

    test "switches language via language switcher without losing state", %{
      conn: conn,
      username: username
    } do
      # Start in English
      view = start_view(conn, username)

      # Open language dropdown
      view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

      # Verify dropdown is open
      assert render(view) =~ "role=\"menu\""

      # Switch to German (don't use change_locale helper as it toggles again)
      # It returns {:ok, conn} for external redirects (which we use for locale change)
      {:ok, conn} =
        view
        |> element("button[phx-click='change_locale'][phx-value-locale='de']")
        |> render_click()
        |> follow_redirect(conn)

      {:ok, view, _html} = live(conn)

      # Verify dropdown closed (in the NEW view)
      refute render(view) =~ "role=\"menu\""

      # Verify Gettext locale updated
      assert Gettext.get_locale(TymeslotWeb.Gettext) == "de"
    end

    test "accepts Accept-Language header for initial locale", %{conn: conn, username: username} do
      conn = put_req_header(conn, "accept-language", "uk-UA,uk;q=0.9")

      view = start_view(conn, username)
      assert render(view) =~ "data-locale=\"uk\""
    end

    test "language switcher displays all supported locales", %{conn: conn, username: username} do
      {:ok, view, _html} = live(conn, "/#{username}")

      # Open language dropdown first so items are rendered
      html = view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

      # Verify language switcher is present
      assert html =~ "language-switcher"

      # All three locales should be available in the dropdown
      assert html =~ "phx-value-locale=\"en\""
      assert html =~ "phx-value-locale=\"de\""
      assert html =~ "phx-value-locale=\"uk\""
    end
  end

  describe "language switcher UI interactions" do
    test "opens and closes language dropdown", %{conn: conn, username: username} do
      view = start_view(conn, username)

      # Initially closed
      refute render(view) =~ "role=\"menu\""

      # Open dropdown
      html = view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()
      assert html =~ "role=\"menu\""

      # phx-click-away must always be present so the binding is registered on the
      # already-mounted element — not only after the dropdown opens via a DOM patch.
      # A conditional phx-click-away on an existing element is never picked up by
      # LiveView's JS, which is why clickaway silently breaks in the browser.
      assert html =~ ~s(phx-click-away="close_language_dropdown")

      # Close via the click-away event (simulates clicking outside)
      render_click(view, "close_language_dropdown", %{})
      refute render(view) =~ "role=\"menu\""

      # phx-click-away must still be present when the dropdown is closed so the
      # binding remains registered for the next open cycle
      assert render(view) =~ ~s(phx-click-away="close_language_dropdown")
    end

    test "shows current language as active in dropdown", %{conn: conn, username: username} do
      view = start_view(conn, username, "de")

      # Open dropdown
      html =
        view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

      # Current language should have active class
      assert html =~ "active"
    end
  end

  describe "locale fallback behavior" do
    test "falls back to English for unsupported locale", %{conn: conn, username: username} do
      view = start_view(conn, username, "es")

      # Should fall back to English
      assert render(view) =~ "data-locale=\"en\""
    end

    test "handles missing Accept-Language header gracefully", %{conn: conn, username: username} do
      view = start_view(conn, username)

      # Should default to English
      assert render(view) =~ "data-locale=\"en\""
    end

    test "handles malformed locale parameter gracefully", %{conn: conn, username: username} do
      view = start_view(conn, username, "invalid123")

      # Should fall back to English
      assert render(view) =~ "data-locale=\"en\""
    end
  end

  describe "multilingual booking flow completeness" do
    test "completes full booking flow in German", %{conn: conn, username: username} do
      view = start_view(conn, username, "de", "30min")

      # Verify we're in German
      assert render(view) =~ "data-locale=\"de\""

      # Flow should work regardless of language
      assert has_element?(view, "[data-testid='duration-option']")
    end

    test "completes full booking flow in Ukrainian", %{conn: conn, username: username} do
      view = start_view(conn, username, "uk", "30min")

      # Verify we're in Ukrainian
      assert render(view) =~ "data-locale=\"uk\""

      # Flow should work regardless of language
      assert has_element?(view, "[data-testid='duration-option']")
    end

    test "language persists throughout booking flow steps", %{conn: conn, username: username} do
      view = start_view(conn, username, "de", "30min")

      # Start in German
      assert render(view) =~ "data-locale=\"de\""
      assert has_element?(view, "[data-testid='duration-option']")

      # Verify the locale is still German
      assert render(view) =~ "data-locale=\"de\""
    end

    test "persists language selection on meeting management pages", %{
      conn: conn,
      username: username,
      user: user
    } do
      meeting = insert(:meeting, organizer_user: user)

      # Start on cancel page in English
      {:ok, view, _html} = live(conn, "/#{username}/meeting/#{meeting.uid}/cancel")
      assert render(view) =~ "data-locale=\"en\""

      # Switch to German via dropdown
      view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

      {:ok, conn} =
        view
        |> element("button[phx-click='change_locale'][phx-value-locale='de']")
        |> render_click()
        |> follow_redirect(conn)

      # Verify we stayed on the cancel page (BUG FIX: previously redirected to overview)
      assert conn.path_info == [username, "meeting", meeting.uid, "cancel"]

      {:ok, new_view, _html} = live(conn)
      assert render(new_view) =~ "data-locale=\"de\""
    end
  end

  # Helper Functions

  defp start_view(conn, username, locale \\ nil, duration \\ nil) do
    url = "/#{username}"

    query_params =
      URI.encode_query(
        Enum.reject([locale: locale, duration: duration], fn {_key, v} -> is_nil(v) end)
      )

    url = if query_params == "", do: url, else: "#{url}?#{query_params}"

    {:ok, view, _html} = live(conn, url)

    view
  end
end
