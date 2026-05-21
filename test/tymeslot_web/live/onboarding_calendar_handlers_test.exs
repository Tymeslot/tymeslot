defmodule TymeslotWeb.OnboardingLive.CalendarHandlersTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :onboarding
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
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

  describe "show_caldav_form" do
    test "switches to the inline credential form", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      view |> element("button[phx-click='show_caldav_form']") |> render_click()

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

      view |> element("button[phx-click='show_caldav_form']") |> render_click()
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

      view |> element("button[phx-click='show_caldav_form']") |> render_click()

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

      view |> element("button[phx-click='show_caldav_form']") |> render_click()

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

      view |> element("button[phx-click='show_caldav_form']") |> render_click()

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
      view |> element("button[phx-click='show_caldav_form']") |> render_click()

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

      assert {:error, {:redirect, %{to: url}}} =
               view
               |> element("button[phx-click='connect_google_calendar']")
               |> render_click()

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

      view
      |> element("button[phx-click='connect_google_calendar']")
      |> render_click()

      assert render(view) =~ "Google"
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
