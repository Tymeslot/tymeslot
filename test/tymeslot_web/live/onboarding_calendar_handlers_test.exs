defmodule TymeslotWeb.OnboardingLive.CalendarHandlersTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :onboarding
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.OnboardingLive.NavigationHandlers

  describe "caldav form" do
    test "switches to the inline credential form", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)

      html = render(view)
      assert html =~ "Server URL"
      assert html =~ "Username"
      assert html =~ "Password"
      assert html =~ "Discover calendars"
    end
  end

  describe "cancel_caldav" do
    test "returns to provider selection and clears form state", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)
      assert render(view) =~ "Server URL"

      view |> element("button[phx-click='cancel_caldav']") |> render_click()

      html = render(view)
      assert html =~ "Google Calendar"
      assert html =~ "Outlook Calendar"
      refute html =~ "Discover calendars"
    end
  end

  describe "validate_caldav" do
    test "marks missing fields as errors but keeps the form open", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)

      # phx-change for the inline form fires `validate_caldav`. Submitting blank
      # values exercises the same path the LiveView uses on every keystroke.
      html =
        view
        |> form("#caldav-form", %{"url" => "", "username" => "", "password" => ""})
        |> render_change()

      assert html =~ "Server URL is required"
      assert html =~ "Username is required"
      assert html =~ "Password is required"
    end

    test "does not mark a field as an error once it has a value", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)

      html =
        view
        |> form("#caldav-form", %{
          "url" => "https://cal.example.com",
          "username" => "alice",
          "password" => ""
        })
        |> render_change()

      refute html =~ "Server URL is required"
      refute html =~ "Username is required"
      assert html =~ "Password is required"
    end
  end

  # Choosing the Google tile goes straight out to Google's sign-in.
  defp continue_with_google(view) do
    view |> element(~s{button[phx-value-option="google"]}) |> render_click()
  end

  describe "connect_google_calendar" do
    test "redirects externally to the OAuth start URL", %{conn: conn} do
      original = Application.get_env(:tymeslot, :google_calendar_oauth_helper)

      Application.put_env(
        :tymeslot,
        :google_calendar_oauth_helper,
        TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperStub
      )

      on_exit(fn ->
        if original do
          Application.put_env(:tymeslot, :google_calendar_oauth_helper, original)
        else
          Application.delete_env(:tymeslot, :google_calendar_oauth_helper)
        end
      end)

      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      assert {:error, {:redirect, %{to: url}}} = continue_with_google(view)

      assert url =~ "accounts.google.com"
    end

    test "surfaces an error flash when the OAuth helper raises", %{conn: conn} do
      original = Application.get_env(:tymeslot, :google_calendar_oauth_helper)

      Application.put_env(
        :tymeslot,
        :google_calendar_oauth_helper,
        TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperRaisesStub
      )

      on_exit(fn ->
        if original do
          Application.put_env(:tymeslot, :google_calendar_oauth_helper, original)
        else
          Application.delete_env(:tymeslot, :google_calendar_oauth_helper)
        end
      end)

      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      continue_with_google(view)

      assert render(view) =~ "Google"
    end

    test "forwards the Google account as login_hint for Google-signup users", %{conn: conn} do
      original = Application.get_env(:tymeslot, :google_calendar_oauth_helper)

      Application.put_env(
        :tymeslot,
        :google_calendar_oauth_helper,
        TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperHintStub
      )

      on_exit(fn ->
        if original do
          Application.put_env(:tymeslot, :google_calendar_oauth_helper, original)
        else
          Application.delete_env(:tymeslot, :google_calendar_oauth_helper)
        end
      end)

      {:ok, view, _html, _user} =
        setup_onboarding(conn, %{
          google_user_id: "google-123",
          provider: "google",
          provider_email: "alice@gmail.com"
        })

      view = navigate_to_calendar_step(view)

      assert {:error, {:redirect, %{to: url}}} = continue_with_google(view)

      assert url =~ "login_hint=" <> URI.encode_www_form("alice@gmail.com")
    end

    test "omits login_hint for non-Google users", %{conn: conn} do
      original = Application.get_env(:tymeslot, :google_calendar_oauth_helper)

      Application.put_env(
        :tymeslot,
        :google_calendar_oauth_helper,
        TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperHintStub
      )

      on_exit(fn ->
        if original do
          Application.put_env(:tymeslot, :google_calendar_oauth_helper, original)
        else
          Application.delete_env(:tymeslot, :google_calendar_oauth_helper)
        end
      end)

      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      assert {:error, {:redirect, %{to: url}}} = continue_with_google(view)

      refute url =~ "login_hint="
    end

    test "returns a host who came from the share step to it", %{conn: conn} do
      original = Application.get_env(:tymeslot, :google_calendar_oauth_helper)

      Application.put_env(
        :tymeslot,
        :google_calendar_oauth_helper,
        TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperHintStub
      )

      on_exit(fn ->
        if original do
          Application.put_env(:tymeslot, :google_calendar_oauth_helper, original)
        else
          Application.delete_env(:tymeslot, :google_calendar_oauth_helper)
        end
      end)

      {:ok, view, _html} = live(conn_for_host_with_calendar(conn), "/onboarding/ready")
      render_click(view, "return_to_calendar_step")

      assert {:error, {:redirect, %{to: url}}} = continue_with_google(view)

      assert URI.decode_query(URI.parse(url).query)["return_to"] ==
               "/onboarding/connect_calendar?return=share"
    end
  end

  describe "continuing from the calendar step" do
    test "a connected calendar continues to the meeting step", %{conn: conn} do
      {:ok, view, _html} =
        live(conn_for_host_with_calendar(conn), "/onboarding/connect_calendar")

      click_continue(view)

      assert has_element?(view, ".onboarding-step-title", "Your meeting")
    end

    test "the OAuth return of a host sent back from the share step goes back to it",
         %{conn: conn} do
      {:ok, view, _html} =
        live(conn_for_host_with_calendar(conn), "/onboarding/connect_calendar?return=share")

      click_continue(view)

      assert has_element?(view, ".onboarding-step-title", "You're live")
    end
  end

  describe "featured Google card" do
    test "is shown with the account email for Google-signup users", %{conn: conn} do
      {:ok, view, _html, _user} =
        setup_onboarding(conn, %{
          google_user_id: "google-123",
          provider: "google",
          provider_email: "alice@gmail.com"
        })

      html = view |> navigate_to_calendar_step() |> render()

      assert html =~ "Recommended"
      assert html =~ "alice@gmail.com"
      # The Google choice card is present and selectable.
      assert html =~ ~s(phx-value-option="google")
      assert has_element?(view, ~s{button[phx-value-option="google"]})
    end

    test "is hidden for non-Google users", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      html = view |> navigate_to_calendar_step() |> render()

      refute html =~ "Recommended"
      assert html =~ "Google Calendar"
    end
  end

  describe "connected google account" do
    test "renders a read-only connected row and drops the google choice card",
         %{conn: conn} do
      # Insert the connected integration BEFORE mounting so the connected
      # calendars are picked up on mount; mirror setup_onboarding's login.
      user =
        insert(:user, %{
          onboarding_completed_at: nil,
          google_user_id: "google-123",
          provider: "google",
          provider_email: "alice@gmail.com"
        })

      insert(:calendar_integration,
        user: user,
        provider: "google",
        provider_account_email: "alice@gmail.com",
        name: "Google Calendar"
      )

      insert(:profile, user: user, username: "alice#{System.unique_integer([:positive])}")

      stub_free_calendar()
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/onboarding/connect_calendar")

      html = render(view)

      # Connected row, not a choice card.
      assert has_element?(view, "div.onboarding-connected-calendar")
      assert html =~ "alice@gmail.com"
      assert html =~ "Google · Connected"

      # The recommended badge and the google CHOICE card are both gone.
      refute html =~ "Recommended"
      refute has_element?(view, ~s{button[phx-value-option="google"]})
    end
  end

  describe "no way past the calendar without one" do
    test "the calendar step has no skip", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      assert has_element?(view, ".onboarding-provider-cards")
      refute has_element?(view, ~s{[phx-value-option="skip"]})
      refute has_element?(view, "#skip-calendar-modal")

      # A forged skip choice is ignored, and Continue stays put.
      render_click(view, "select_calendar_option", %{"option" => "skip"})
      assert has_element?(view, "button[phx-click='next_step'][disabled]")
    end

    test "there is no way past the calendar step without a bookable calendar",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      assert has_element?(view, "button[phx-click='next_step'][disabled]")

      # Pressed anyway, as a forged event would.
      render_click(view, "next_step", %{})

      assert has_element?(view, ".onboarding-step-title", "Your calendar")
      assert has_element?(view, "button[phx-click='next_step'][disabled]")
    end

    test "choosing a tile does not unlock Continue on its own", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)
      view |> element("button[phx-click='cancel_caldav']") |> render_click()

      assert has_element?(view, "button[phx-click='next_step'][disabled]")
    end

    test "an inactive calendar does not unlock the step", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      insert(:profile, user: user, username: "inactive#{System.unique_integer([:positive])}")
      insert(:calendar_integration, user: user, is_active: false)

      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")

      assert has_element?(
               view,
               ~s([data-role="calendar-not-bookable"]),
               "This calendar is paused, so it can't take bookings. Reconnect it or connect another."
             )

      assert has_element?(view, "button[phx-click='next_step'][disabled]")

      # Connecting another stays open.
      assert has_element?(view, ~s{button[phx-value-option="google"]})
    end

    test "the skip-setup events no longer exist", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      refute has_element?(view, "#skip-onboarding-modal")

      # Their modals are no longer registered, so nothing can open them.
      for modal <- [:skip, :skip_calendar] do
        assert_raise ArgumentError, fn ->
          ModalHook.show_modal(%Phoenix.LiveView.Socket{}, modal)
        end
      end

      Code.ensure_loaded!(NavigationHandlers)

      for handler <- [
            :handle_show_skip_modal,
            :handle_hide_skip_modal,
            :handle_skip_onboarding,
            :handle_confirm_skip_calendar,
            :handle_hide_skip_calendar_modal
          ] do
        refute function_exported?(NavigationHandlers, handler, 1),
               "#{handler} should no longer exist"
      end
    end
  end

  describe "the tiles" do
    test "every provider has its own tile with its logo, and a privacy line", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      for {option, name, logo} <- [
            {"google", "Google Calendar", "google"},
            {"outlook", "Outlook Calendar", "outlook"},
            {"apple", "Apple Calendar", "apple"},
            {"caldav", "Other calendar (CalDAV)", "caldav"}
          ] do
        tile = ~s{button[phx-value-option="#{option}"]}
        assert has_element?(view, tile, name)
        assert has_element?(view, ~s{#{tile} img[src*="/providers/calendar/"][src*="#{logo}"]})
      end

      assert has_element?(
               view,
               ".onboarding-privacy-line",
               "We only read when you're busy, never what your events are."
             )
    end
  end

  describe "a paused calendar" do
    defp mount_with_paused(conn, attrs) do
      stub_free_calendar()
      user = insert(:user, onboarding_completed_at: nil)
      insert(:profile, user: user, username: "paused#{System.unique_integer([:positive])}")
      calendar = insert(:calendar_integration, Map.merge(%{user: user, is_active: false}, attrs))
      {:ok, view, _html} = live(log_in_user(conn, user), "/onboarding/connect_calendar")
      {view, calendar}
    end

    test "a paused Google calendar shows as paused, and Google can be connected again",
         %{conn: conn} do
      original = Application.get_env(:tymeslot, :google_calendar_oauth_helper)

      Application.put_env(
        :tymeslot,
        :google_calendar_oauth_helper,
        TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperStub
      )

      on_exit(fn ->
        if original,
          do: Application.put_env(:tymeslot, :google_calendar_oauth_helper, original),
          else: Application.delete_env(:tymeslot, :google_calendar_oauth_helper)
      end)

      {view, calendar} =
        mount_with_paused(conn, %{provider: "google", provider_account_email: "host@gmail.com"})

      row = ~s([data-calendar-state="paused"])
      assert has_element?(view, row, "host@gmail.com")
      assert has_element?(view, row, "Google · Paused")
      refute has_element?(view, ~s([data-calendar-state="connected"]))
      assert has_element?(view, ~s{button[phx-value-option="google"]})

      # The row's own Reconnect goes out to Google's sign-in again.
      assert {:error, {:redirect, %{to: url}}} =
               view
               |> element(~s{#{row} button[phx-value-id="#{calendar.id}"]}, "Reconnect")
               |> render_click()

      assert url =~ "accounts.google.com"
    end

    test "a paused CalDAV calendar can still open the CalDAV form, and reconnect from its row",
         %{conn: conn} do
      {view, calendar} = mount_with_paused(conn, %{provider: "caldav"})

      assert has_element?(view, ~s([data-calendar-state="paused"]), "CalDAV · Paused")

      # The tile opens a new connection.
      open_caldav_form(view)
      assert has_element?(view, "#caldav-form", "Discover calendars")
      view |> element("button[phx-click='cancel_caldav']") |> render_click()

      # The row reconnects this calendar, starting from its server.
      view
      |> element(~s{button[phx-click="reconnect_calendar"][phx-value-id="#{calendar.id}"]})
      |> render_click()

      assert has_element?(view, "#caldav-form", "Reconnect")
      assert has_element?(view, ~s{#caldav-form input[name="url"][value="#{calendar.base_url}"]})
    end
  end

  defp conn_for_host_with_calendar(conn) do
    stub_free_calendar()
    user = insert(:user, onboarding_completed_at: nil)
    insert(:profile, user: user, username: "calhost#{System.unique_integer([:positive])}")
    insert(:calendar_integration, user: user)
    log_in_user(conn, user)
  end
end

defmodule TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperStub do
  @moduledoc false
  @spec authorization_url(integer(), String.t(), keyword()) :: String.t()
  def authorization_url(_user_id, _redirect_uri, _opts),
    do: "https://accounts.google.com/o/oauth2/v2/auth?state=test"
end

defmodule TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperRaisesStub do
  @moduledoc false
  @spec authorization_url(integer(), String.t(), keyword()) :: no_return()
  def authorization_url(_user_id, _redirect_uri, _opts),
    do: raise("Client ID not configured")
end

defmodule TymeslotWeb.OnboardingLive.CalendarHandlersTest.GoogleHelperHintStub do
  @moduledoc false
  # Echoes the forwarded options (bar the PKCE flow the context adds) into the
  # URL query so the handler test can assert whether `login_hint` was passed
  # through.
  @spec authorization_url(integer(), String.t(), keyword()) :: String.t()
  def authorization_url(_user_id, _redirect_uri, opts) do
    query =
      opts
      |> Keyword.delete(:pkce)
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> URI.encode_query()

    "https://accounts.google.com/o/oauth2/v2/auth?" <> query
  end
end
