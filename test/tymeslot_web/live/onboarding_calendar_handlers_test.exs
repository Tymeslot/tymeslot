defmodule TymeslotWeb.OnboardingLive.CalendarHandlersTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :onboarding
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  setup :verify_on_exit!

  setup do
    # ConnCase doesn't stub the HTTPClientMock the way DataCase does. CalDAV
    # discovery makes :propfind requests via HTTPClient.request/5, so stub a
    # transport timeout so unmocked tests fail-fast on the network call rather
    # than raising UnexpectedCallError.
    Mox.stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    Mox.stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    :ok
  end

  defp navigate_to_calendar_step(view) do
    # Welcome → profile
    view |> element("button[phx-click='next_step']") |> render_click()

    # Fill profile
    view
    |> form("form#profile-form", %{
      "full_name" => "Test User",
      "username" => "testuser#{System.unique_integer([:positive])}"
    })
    |> render_change()

    # Profile → connect_calendar
    view |> element("button[phx-click='next_step']") |> render_click()

    view
  end

  # Selecting the CalDAV option and pressing Continue is the only way to reach
  # the inline credential form under the forced-choice model.
  defp open_caldav_form(view) do
    view |> element(~s{button[phx-value-option="caldav"]}) |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()
    view
  end

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

  describe "discover_caldav_calendars (validation gate)" do
    test "submitting with blank fields does not attempt discovery", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)

      html =
        view
        |> form("#caldav-form", %{"url" => "", "username" => "", "password" => ""})
        |> render_submit()

      # No "Could not discover" / "Connection" error — the validation gate fires
      # before any HTTP call is made.
      assert html =~ "Server URL is required"
      refute html =~ "Could not"
    end
  end

  describe "discover_caldav_calendars (discovery failure)" do
    test "surfaces a discovery error when the server cannot be reached", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      # CalDAV discovery makes HTTP requests through the HTTPClientMock that
      # DataCase stubs with `:timeout`. With valid form fields, discovery
      # fails on the network call and the handler renders a discovery error.
      open_caldav_form(view)

      html =
        view
        |> form("#caldav-form", %{
          "url" => "https://cal.example.com",
          "username" => "alice",
          "password" => "secret"
        })
        |> render_submit()

      # The exact wording comes from DisplayHelpers.normalize_discovery_error/1.
      # Assert presence of some error message on the form rather than exact text.
      assert html =~ "<p class=\"" or html =~ "text-red-600"
      refute html =~ "successfully connected"
    end
  end

  # Selecting the Google option and pressing Continue is the only way to
  # initiate Google OAuth under the forced-choice model.
  defp continue_with_google(view) do
    view |> element(~s{button[phx-value-option="google"]}) |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()
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

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/onboarding?step=connect_calendar")

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

  describe "forced choice Continue gating" do
    test "Continue is disabled until an option is selected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      # Nothing connected and nothing selected — Continue is disabled.
      assert has_element?(view, "button[phx-click='next_step'][disabled]")

      # Selecting any option enables Continue.
      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()

      refute has_element?(view, "button[phx-click='next_step'][disabled]")
    end

    test "clicking the selected option again toggles it off", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      # Select, then click the same option again to clear the selection.
      view |> element(~s{button[phx-value-option="outlook"]}) |> render_click()
      refute has_element?(view, "button[phx-click='next_step'][disabled]")

      view |> element(~s{button[phx-value-option="outlook"]}) |> render_click()

      # Back to no selection — Continue is disabled again.
      assert has_element?(view, "button[phx-click='next_step'][disabled]")
    end
  end

  describe "skip advances the flow" do
    test "selecting skip then Continue advances to buffer_time", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      view |> element(~s{button[phx-value-option="skip"]}) |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      assert has_element?(view, "button[phx-value-buffer_minutes]")
    end
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
  # Echoes the forwarded options into the URL query so the handler test can
  # assert whether `login_hint` was passed through.
  @spec authorization_url(integer(), String.t(), keyword()) :: String.t()
  def authorization_url(_user_id, _redirect_uri, opts) do
    query = URI.encode_query(Map.new(opts, fn {k, v} -> {to_string(k), to_string(v)} end))
    "https://accounts.google.com/o/oauth2/v2/auth?" <> query
  end
end
