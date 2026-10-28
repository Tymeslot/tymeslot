defmodule TymeslotWeb.Dashboard.RefusedCalendarReconnectJourneyTest do
  @moduledoc """
  The owner's journey through a calendar whose credentials were refused: the
  provider rejects them, the dashboard and the owner's own booking page say
  which calendar needs reconnecting and the setup checklist stops calling the
  calendar done, then the owner reconnects it through the CalDAV reconnect
  flow and every one of those warnings goes away again.
  """

  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Tymeslot.AuthTestHelpers

  @moduletag :integration
  @moduletag :calendar

  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Onboarding
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.CalDAVAccountStub
  alias Tymeslot.TestMocks

  @dashboard_notice "#refused-calendar-notice"
  @booking_notice "[data-testid='calendar-refused-notice']"
  @checklist "[data-testid=onboarding-checklist]"
  @calendar_cta "#{@checklist} a[href='/dashboard/integrations?tab=calendars']"

  @dav_url "https://dav.example.com/remote.php/dav"
  @calendar_path "/remote.php/dav/calendars/bob/work/"

  setup :verify_on_exit!

  setup %{conn: conn} do
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    %{user: user, profile: profile} =
      BookingTestHelpers.seed_booking_account("1", "refusedjourney", "America/New_York")

    {:ok, user} = Onboarding.complete_onboarding(user)
    [integration] = Calendar.list_integrations(user.id)

    # The provider refuses the stored credentials, as a sync's 401 records it.
    assert :ok = ReauthHandling.flag(:calendar, integration, :rejected_credentials)

    conn = conn |> init_test_session(%{}) |> log_in_user(user)
    %{conn: conn, user: user, profile: profile, integration: integration}
  end

  @tag :capture_log
  test "the dashboard warns and un-ticks the calendar until it is reconnected",
       %{conn: conn, user: user, integration: integration} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    assert view |> element(@dashboard_notice) |> render() =~
             "#{integration.name} needs reconnecting. Until you reconnect it, your booking page may not offer times or take bookings."

    assert render(view) =~ "Reconnect #{integration.name}: until you do"
    assert has_element?(view, @calendar_cta)

    reconnect!(user, integration)

    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    refute has_element?(view, @dashboard_notice)
    refute render(view) =~ "Reconnect #{integration.name}"
    # The widget stays up (video is still outstanding), so the missing
    # calendar link means the item is ticked rather than the widget gone.
    assert has_element?(view, @checklist)
    refute has_element?(view, @calendar_cta)
  end

  @tag :capture_log
  test "the owner's booking page warns until the calendar is reconnected",
       %{conn: conn, user: user, profile: profile, integration: integration} do
    path = "/#{profile.username}?timezone=#{profile.timezone}"

    {:ok, view, _html} = live(conn, path)
    assert view |> element(@booking_notice) |> render() =~ integration.name

    reconnect!(user, integration)

    {:ok, view, _html} = live(conn, path)
    refute has_element?(view, @booking_notice)
  end

  # The owner's CalDAV reconnect: discovery against the new credentials, then
  # the calendar picked from what it found.
  defp reconnect!(user, integration) do
    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      CalDAVAccountStub.answer(%{calendars: [@calendar_path]}, method, url, body)
    end)

    params = %{"url" => @dav_url, "username" => "bob", "password" => "new-password"}

    assert {:ok, :needs_calendar_selection, payload} =
             Calendar.reconnect_caldav_integration(user.id, integration.id, params)

    assert [%{path: path}] = payload.calendars

    assert {:ok, %{needs_reauth: false}} =
             Calendar.finalise_caldav_reconnect(user.id, integration.id, %{
               payload: payload,
               selected_paths: [path]
             })
  end
end
