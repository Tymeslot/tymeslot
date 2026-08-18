defmodule TymeslotWeb.Live.MultilingualBookingTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Locales

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
      conn = put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

      view = start_view(conn, username)
      assert render(view) =~ "data-locale=\"de\""
    end

    test "language switcher displays all supported locales", %{conn: conn, username: username} do
      {:ok, view, _html} = live(conn, "/#{username}")

      # Open language dropdown first so items are rendered
      html = view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

      # Verify language switcher is present
      assert html =~ "language-switcher"

      supported = Locales.supported_codes()
      refute supported == []

      # Every supported locale is offered as a switch option...
      for code <- supported do
        assert html =~ ~s(phx-value-locale="#{code}")
      end

      # ...and no others: exactly one change_locale option per supported locale.
      option_count =
        html |> String.split(~s(phx-click="change_locale")) |> length() |> Kernel.-(1)

      assert option_count == length(supported)
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

      # phx-click-away is wired only while the dropdown is open — the component
      # conditionally renders it as `@open && @on_close` so it is absent when closed.
      assert html =~ ~s(phx-click-away="close_language_dropdown")

      # Close via the click-away event (simulates clicking outside)
      render_click(view, "close_language_dropdown", %{})
      refute render(view) =~ "role=\"menu\""

      # phx-click-away is absent when the dropdown is closed
      refute render(view) =~ ~s(phx-click-away="close_language_dropdown")
    end

    test "shows current language as active in dropdown", %{conn: conn, username: username} do
      view = start_view(conn, username, "de")

      # Open dropdown
      html =
        view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

      # Exactly the current locale's option carries the `active` marker. A bare
      # `html =~ "active"` matches any number of unrelated attributes and class
      # names on the page, so it could never fail.
      active_locales =
        html
        |> Floki.parse_document!()
        |> Floki.find("button[phx-click='change_locale'].active")
        |> Floki.attribute("phx-value-locale")

      assert active_locales == ["de"]
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

  describe "pseudo locale on booking themes" do
    # async: false at module level already toggles this global application env.
    setup do
      original = Application.get_env(:tymeslot, :pseudo_locale_enabled)
      Application.put_env(:tymeslot, :pseudo_locale_enabled, true)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:tymeslot, :pseudo_locale_enabled)
        else
          Application.put_env(:tymeslot, :pseudo_locale_enabled, original)
        end

        Gettext.put_locale(TymeslotWeb.Gettext, "en")
      end)

      :ok
    end

    test "LocaleHook keeps the pseudo locale carried over from the session instead of " <>
           "resetting to the default",
         %{conn: conn, username: username} do
      # First request: LocalePlug accepts ?locale=pseudo and persists it to the session.
      conn = get(conn, "/#{username}?locale=pseudo")

      # Second navigation carries NO locale param, so the Dispatcher LiveView's own
      # `handle_params` locale sync (which only fires when `params["locale"]` is
      # present) is a no-op — resolution falls entirely to LocaleHook reading the
      # session. This is what isolates the hook's own acceptance check.
      conn = get(recycle(conn), "/#{username}")
      {:ok, view, _html} = live(conn)

      html = render(view)
      assert html =~ ~s(data-locale="pseudo")
      # Pseudo-localisation coverage markers on the always-rendered greeting —
      # proves the booking theme actually renders pseudo text, not just the assign.
      assert html =~ "⟦"
    end
  end

  describe "multilingual booking flow completeness" do
    test "completes full booking flow in every supported locale", %{
      conn: conn,
      username: username
    } do
      supported = Locales.supported_codes()
      refute supported == []

      # The booking flow must render end-to-end in each supported locale,
      # including the non-default ones.
      for locale <- supported do
        view = start_view(conn, username, locale, "30min")

        assert render(view) =~ ~s(data-locale="#{locale}")
        assert has_element?(view, "[data-testid='duration-option']")
      end
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
