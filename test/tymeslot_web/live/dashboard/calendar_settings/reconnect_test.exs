defmodule TymeslotWeb.Dashboard.CalendarSettings.ReconnectTest do
  @moduledoc """
  Tests the Reconnect button on calendar cards in the calendar settings
  LiveComponent. For OAuth providers (Google, Outlook) the parent
  re-uses its `connect_provider` event to kick off the OAuth flow,
  sending `{:external_redirect, url}` to the parent LiveView, which
  then redirects the browser. For CalDAV-family providers the button
  targets `CaldavReconnectModal` directly via `show_reconnect`; that
  modal owns its own form state and lifecycle.
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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element(
        "button[phx-click='connect_provider'][phx-value-provider='google'][title='Reconnect integration']"
      )
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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element(
        "button[phx-click='connect_provider'][phx-value-provider='outlook'][title='Reconnect integration']"
      )
      |> render_click()

      assert_redirect(view, expected_url)
    end
  end

  describe "CalDAV reconnect error paths" do
    test "flashes an error when the supplied id cannot be parsed as an integer", %{
      conn: conn,
      user: user
    } do
      # Insert a valid CalDAV integration so the Reconnect button exists
      # in the DOM. We then override phx-value-id with a non-integer to
      # drive the modal's `parse_int/1` `:error` branch — simulating a
      # tampered client payload that must surface a flash, not crash.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          name: "My CalDAV",
          base_url: "https://caldav.example.com",
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("oldpass"),
          is_active: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='show_reconnect'][phx-value-id='#{integration.id}']")
      |> render_click(%{"id" => "abc"})

      assert render(view) =~ "Invalid calendar ID"
    end

    test "flashes an error when the id belongs to a different user", %{
      conn: conn,
      user: user
    } do
      # Another user with an integration whose id we hand to the current
      # user's session. `Calendar.get_integration/2` scopes by user, so
      # it returns `{:error, :not_found}` — the modal must surface the
      # corresponding flash rather than open with someone else's data.
      other_user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: other_user)

      other_integration =
        insert(:calendar_integration,
          user: other_user,
          provider: "caldav",
          name: "Someone Else's",
          base_url: "https://caldav.example.com",
          username_encrypted: Encryption.encrypt("bob"),
          password_encrypted: Encryption.encrypt("secret"),
          is_active: true
        )

      own_integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          name: "Mine",
          base_url: "https://caldav.example.com",
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("secret"),
          is_active: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='show_reconnect'][phx-value-id='#{own_integration.id}']")
      |> render_click(%{"id" => to_string(other_integration.id)})

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

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # A needs_reauth integration surfaces its Reconnect control on the
      # collapsed header, so click it without expanding the row.
      html =
        view
        |> element("button[phx-click='show_reconnect'][phx-value-id='#{integration.id}']")
        |> render_click()

      assert html =~ "Reconnect My CalDAV"
      assert html =~ "https://caldav.example.com"
      assert html =~ "alice"
      refute html =~ ~s(name="reconnect[password]" value="oldpass")
    end
  end

  describe "CalDAV reconnect modal (mailbox.org URL is locked)" do
    test "the URL field is disabled and pinned to https://dav.mailbox.org",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          name: "My mailbox.org",
          provider: "mailbox_org",
          base_url: "https://dav.mailbox.org",
          username_encrypted: Encryption.encrypt("alice@mailbox.org"),
          password_encrypted: Encryption.encrypt("oldpass"),
          calendar_paths: ["/caldav/abc123/"],
          provider_account_id: "https://dav.mailbox.org||alice@mailbox.org",
          is_active: true,
          needs_reauth: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # A needs_reauth integration surfaces its Reconnect control on the
      # collapsed header, so click it without expanding the row.
      html =
        view
        |> element("button[phx-click='show_reconnect'][phx-value-id='#{integration.id}']")
        |> render_click()

      doc = Floki.parse_document!(html)

      hidden_url =
        Floki.find(doc, ~s|input[type="hidden"][name="reconnect[url]"]|)

      assert hidden_url != [], "expected a hidden reconnect[url] input for the locked field"
      assert Floki.attribute(hidden_url, "value") == ["https://dav.mailbox.org"]

      disabled_input =
        Floki.find(doc, ~s|input[type="text"][value="https://dav.mailbox.org"][disabled]|)

      assert disabled_input != [],
             "expected a disabled, greyed-out URL input for mailbox.org reconnect"

      # The editable URL input from the non-locked branch must not be rendered.
      refute Floki.find(doc, ~s|input[type="url"][name="reconnect[url]"]|) != []
    end
  end
end
