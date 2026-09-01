defmodule TymeslotWeb.OnboardingLive.CaldavDiscoveryTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :onboarding
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Integrations.Calendar

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

  # A minimal 207 Multi-Status PROPFIND response with one discoverable
  # calendar. Mirrors the stub used in DiscoveryHappyPathTest and
  # DiscoveryTest's Baikal case — the mock ignores method/url/body, so this
  # single response satisfies whichever PROPFIND round-trip the CalDAV
  # discovery chain issues.
  @propfind_calendar_response """
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/calendars/user/personal/</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname>Personal</D:displayname>
          <D:resourcetype>
            <D:collection/>
            <C:calendar/>
          </D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  defp stub_caldav_discovery_success do
    Mox.stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 207, body: @propfind_calendar_response}}
    end)
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

  describe "discover_caldav_calendars (async discovery)" do
    test "shows a loading state on the button while discovery runs", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)

      # Discovery is dispatched via start_async, so render_submit returns the
      # intermediate state before the network round-trip completes: the button
      # shows the "Discovering…" label and is disabled rather than freezing.
      # Assert on the render_submit snapshot — a stable point-in-time capture —
      # since the async task may settle before a fresh has_element? query runs.
      # "Discovering" only renders while the disabled `caldav_discovering` state
      # is active, so its presence proves the loading state.
      html =
        view
        |> form("#caldav-form", %{
          "url" => "https://cal.example.com",
          "username" => "alice",
          "password" => "secret"
        })
        |> render_submit()

      assert html =~ "Discovering"
      assert html =~ "disabled"

      # Let the async task settle so it doesn't leak into later assertions.
      render_async(view)
    end

    test "surfaces a discovery error and re-enables the form once it fails", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      # CalDAV discovery makes HTTP requests through the HTTPClientMock stubbed
      # in setup with `:timeout`. With valid form fields, discovery fails on the
      # network call inside the async task. render_async awaits that task, then
      # the handler folds the discovery error back into the form.
      open_caldav_form(view)

      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => "alice",
        "password" => "secret"
      })
      |> render_submit()

      render_async(view)
      html = render(view)

      # The exact wording comes from DisplayHelpers.normalize_discovery_error/1.
      # Assert presence of the discovery error styling rather than exact text —
      # "text-red-600" only renders for the field-error <p> tags, so its
      # presence proves an error was actually surfaced (unlike the previous
      # `html =~ "<p class=\""` disjunct, which is always true because the
      # onboarding layout unconditionally renders `<p class="onboarding-step-description">`).
      assert html =~ "text-red-600"
      refute html =~ "successfully connected"

      # The button is no longer stuck in the discovering state — the user can retry.
      assert html =~ "Discover calendars"
      refute has_element?(view, "button[type='submit'][disabled]")
    end

    test "creates the integration on a successful discovery and advances past the form",
         %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)
      stub_caldav_discovery_success()

      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => "alice",
        "password" => "secret"
      })
      |> render_submit()

      # A successful discovery makes several real PROPFIND round-trips (guessed
      # path plus the RFC 4791 principal chain) before creating and persisting
      # the integration, which comfortably exceeds render_async/1's 100ms
      # default (tuned for a single mocked call) even though every call is
      # instantly stubbed.
      render_async(view, 2000)
      html = render(view)

      integrations = Calendar.list_integrations(user.id)
      assert [integration] = integrations
      assert integration.provider == "caldav"

      # The form is gone — the view fell back to the (now read-only-row)
      # selecting state rather than staying stuck on the discovery form.
      refute html =~ "Discover calendars"
      assert has_element?(view, "div.onboarding-connected-calendar")
    end

    test "an exit at the HTTP boundary is absorbed into a discovery error and re-enables the form",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)

      # An exit rather than a raise, which takes a different route out:
      # `CalendarCircuitBreaker.with_breaker/3` rescues exceptions, and
      # `rescue` does not catch exits. What stops this one is
      # `Tymeslot.Infrastructure.CacheStore.compute_and_store/5` — every
      # discovery runs inside `DiscoveryCache.get_or_compute/2` — whose
      # `catch` resolves any non-local exit to `{:error, :computation_failed}`.
      # So the async task returns normally, `handle_async/3` never sees
      # `{:exit, _}`, and the visitor gets a classified discovery error.
      Mox.stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        exit(:boom)
      end)

      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => "alice",
        "password" => "secret"
      })
      |> render_submit()

      render_async(view)
      html = render(view)

      assert html =~ "An unexpected error occurred with CalDAV server"
      refute html =~ "Something went wrong while contacting the calendar server"
      refute has_element?(view, "button[type='submit'][disabled]")
    end

    test "a raised exception is absorbed by the circuit breaker and shown as a discovery error",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)

      # `validate_config/1` is structural only, so a raised exception now
      # surfaces from inside `CalendarCircuitBreaker.with_breaker/3`, which
      # rescues it into `{:error, _}`. The task therefore does NOT crash: the
      # user sees a discovery error rather than the crash-recovery message,
      # and the form is still re-enabled either way.
      Mox.stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        raise "boom"
      end)

      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => "alice",
        "password" => "secret"
      })
      |> render_submit()

      render_async(view)
      html = render(view)

      refute html =~ "Something went wrong while contacting the calendar server"
      assert has_element?(view, "p.text-red-600")
      refute has_element?(view, "button[type='submit'][disabled]")
    end

    test "surfaces a creation error distinct from a discovery error and re-enables the form",
         %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      # An existing integration with the same computed account id
      # ("#{base_url}||#{username}") makes check_no_duplicate_calendar in
      # Tymeslot.Integrations.Calendar.Creation reject the new one with
      # {:error, :duplicate_integration} — a non-form_errors error, so it
      # folds into {:ok, {:creation_failed, reason}} rather than
      # {:ok, {:form_errors, _}}.
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        provider_account_id: "https://cal.example.com||alice"
      )

      open_caldav_form(view)
      stub_caldav_discovery_success()

      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => "alice",
        "password" => "secret"
      })
      |> render_submit()

      # See the success test above for why this exceeds render_async/1's
      # 100ms default: a real (stubbed) PROPFIND chain runs before the
      # duplicate-account check fails.
      render_async(view, 2000)
      html = render(view)

      assert html =~ "Could not create calendar integration"
      assert html =~ "Discover calendars"
      refute has_element?(view, "button[type='submit'][disabled]")

      # No second integration was persisted for the duplicate attempt.
      assert length(Calendar.list_integrations(user.id)) == 1
    end

    test "surfaces creation-time field errors and re-enables the form", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)
      stub_caldav_discovery_success()

      # Presence-only validation in CalendarHandlers.validate_caldav_fields/1
      # lets this through (username is non-blank), but the creation-time
      # sanitizer (Tymeslot.Integrations.Calendar.InputValidation) rejects
      # usernames over 255 characters, returning {:error, {:form_errors, _}}
      # from create_integration_with_validation/2.
      long_username = String.duplicate("a", 300)

      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => long_username,
        "password" => "secret"
      })
      |> render_submit()

      # See the success test above for why this exceeds render_async/1's
      # 100ms default.
      render_async(view, 2000)
      html = render(view)

      assert html =~ "Username must be 255 characters or less"
      assert html =~ "Discover calendars"
      refute has_element?(view, "button[type='submit'][disabled]")
    end

    test "ignores a second submit while discovery is already in flight", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      view = navigate_to_calendar_step(view)

      open_caldav_form(view)
      stub_caldav_discovery_success()

      # First submit starts the async discovery/creation task and flips
      # caldav_discovering to true.
      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => "alice",
        "password" => "secret"
      })
      |> render_submit()

      # Second submit, with different credentials, arrives while
      # caldav_discovering is still true — the guard in
      # CalendarHandlers.discover_and_create_caldav/2 must no-op it rather
      # than starting a second discovery task.
      view
      |> form("#caldav-form", %{
        "url" => "https://cal.example.com",
        "username" => "mallory",
        "password" => "secret"
      })
      |> render_submit()

      # See the success test above for why this exceeds render_async/1's
      # 100ms default.
      render_async(view, 2000)

      # Only one integration exists, and it was created with the FIRST
      # submission's credentials — proof the second submit never reached
      # discover_and_create_caldav's start_async branch.
      assert [integration] = Calendar.list_integrations(user.id)
      assert integration.username == "alice"
    end
  end
end
