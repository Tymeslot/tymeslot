defmodule TymeslotWeb.Dashboard.CalendarSettings.ReconnectTest do
  @moduledoc """
  Tests the `reconnect_integration` event dispatched from calendar cards in
  the calendar settings LiveComponent. For OAuth providers (Google, Outlook)
  the handler must kick off the provider's OAuth flow by sending
  `{:external_redirect, url}` to the parent LiveView, which then redirects
  the browser. The LiveComponent itself never redirects — it only signals.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :live
  @moduletag :integrations
  @moduletag :calendar

  import Mox
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup :setup_dashboard_user

  describe "OAuth reconnect (Google)" do
    test "clicking Reconnect on a Google integration redirects to the Google OAuth URL",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Work Google",
          base_url: "https://www.googleapis.com/calendar/v3",
          is_active: true
        )

      expected_url = "https://accounts.google.com/o/oauth2/v2/auth?state=reconnect"

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id,
                                                                    _redirect_uri,
                                                                    _opts ->
        expected_url
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click()

      assert_redirect(view, expected_url)
    end
  end

  describe "OAuth reconnect (Outlook)" do
    test "clicking Reconnect on an Outlook integration redirects to the Outlook OAuth URL",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          name: "Work Outlook",
          base_url: "https://graph.microsoft.com/v1.0",
          is_active: true
        )

      expected_url =
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?state=reconnect"

      expect(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _user_id,
                                                                     _redirect_uri,
                                                                     _opts ->
        expected_url
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click()

      assert_redirect(view, expected_url)
    end
  end

  describe "OAuth reconnect error paths" do
    test "flashes an error when the supplied id cannot be parsed as an integer", %{
      conn: conn,
      user: user
    } do
      # Insert a valid integration so the Reconnect button exists in the DOM.
      # We then override the phx-value-id with a non-integer string to drive the
      # `parse_int/1` `:error` branch inside `handle_event/3`. This simulates a
      # tampered client payload — the handler must surface a flash instead of
      # crashing.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Work Google",
          base_url: "https://www.googleapis.com/calendar/v3",
          is_active: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click(%{"id" => "abc"})

      # Flash is forwarded via `send(self(), {:flash, _})` from the component,
      # handled in a separate cycle. Drain the mailbox so the next `render/1`
      # sees the flash.
      _drain = :sys.get_state(view.pid)

      assert render(view) =~ "Invalid calendar ID"
    end

    test "flashes an error when the id belongs to a different user", %{
      conn: conn,
      user: user
    } do
      # Another user with an integration whose id we hand to the current user's
      # session. `Calendar.get_integration/2` scopes by user, so it returns
      # `{:error, :not_found}` — the handler must surface the corresponding
      # flash rather than raise or redirect.
      other_user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: other_user)

      other_integration =
        insert(:calendar_integration,
          user: other_user,
          provider: "google",
          name: "Someone Else's",
          base_url: "https://www.googleapis.com/calendar/v3",
          is_active: true
        )

      # The current user also has a Google integration so the button is in the
      # DOM and can be driven with an overridden phx-value-id.
      own_integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Mine",
          base_url: "https://www.googleapis.com/calendar/v3",
          is_active: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element(
        "button[phx-click='reconnect_integration'][phx-value-id='#{own_integration.id}']"
      )
      |> render_click(%{"id" => to_string(other_integration.id)})

      _drain = :sys.get_state(view.pid)

      assert render(view) =~ "Integration not found"
    end
  end

  describe "CalDAV reconnect modal (password-only path)" do
    test "clicking Reconnect on a CalDAV integration opens the modal with prefilled url + username",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          name: "My CalDAV",
          provider: "caldav",
          base_url: "https://caldav.example.com",
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("oldpass"),
          calendar_paths: ["/calendars/alice/default/"],
          provider_account_id: "https://caldav.example.com||alice",
          is_active: true,
          needs_reauth: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      html =
        view
        |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
        |> render_click()

      assert html =~ "Reconnect My CalDAV"
      assert html =~ "https://caldav.example.com"
      assert html =~ "alice"
      refute html =~ ~s(name="reconnect[password]" value="oldpass")
    end
  end
end
