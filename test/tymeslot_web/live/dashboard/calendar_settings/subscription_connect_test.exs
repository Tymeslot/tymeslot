defmodule TymeslotWeb.Dashboard.CalendarSettings.SubscriptionConnectTest do
  @moduledoc """
  Composition test for subscribing to a published calendar feed from the
  integrations dashboard: picking the tile, submitting the feed URL, and what
  the resulting integration is and is not allowed to be.

  The HTTP boundary is stubbed at `Tymeslot.HTTPClientMock`, the same seam the
  CalDAV connect flow uses, so the pre-save feed probe runs end to end without
  a real publisher.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :integrations
  @moduletag :calendar
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  setup :verify_on_exit!
  setup :setup_dashboard_user

  @feed_url "https://outlook.office365.com/owa/calendar/secret-token/calendar.ics"

  @ics """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Example Corp//Publisher//EN
  BEGIN:VEVENT
  UID:published-event@example.com
  DTSTART:20260810T090000Z
  DTEND:20260810T100000Z
  SUMMARY:Busy
  END:VEVENT
  END:VCALENDAR
  """

  defp stub_feed do
    stub(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: @ics, headers: %{}}}
    end)
  end

  defp subscribe(view, url \\ @feed_url) do
    view
    |> element("button[phx-click='connect_provider'][phx-value-provider='ics_url']")
    |> render_click()

    view
    |> form("#calendar-subscription-form", %{
      "integration" => %{"name" => "Work calendar", "url" => url}
    })
    |> render_submit()

    # `add_subscription` runs the feed probe off the socket's process (see
    # `ConfigViewComponent.handle_event/3`), which comfortably exceeds
    # `render_async/1`'s 100ms default under load.
    render_async(view, 5000)
  end

  # `picker_groups/2` (`CalendarSettingsComponent`) files each provider under
  # its group's `<h3>` label, followed by the grid `<div>` holding that
  # group's tiles. `has_element?/2` can't scope on that adjacency — LiveView
  # 1.2's test selector engine (`LazyHTML`) has no text-matching pseudo-class
  # — so this parses the markup directly with `Floki` (which does) and finds
  # the provider button inside the `<div>` immediately following the group's
  # `<h3>`, rather than trusting the page-wide text a mislabelled tile would
  # still satisfy.
  defp group_tile?(html, group_label, provider) do
    html
    |> Floki.parse_document!()
    |> Floki.find(
      ~s|h3:fl-contains("#{group_label}") + div button[phx-value-provider='#{provider}']|
    )
    |> Enum.any?()
  end

  describe "subscribing to a feed" do
    @tag :capture_log
    test "the tile is filed under subscriptions, not under CalDAV servers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      assert html =~ "Calendar subscriptions"
      assert group_tile?(html, "Calendar subscriptions", "ics_url")
      refute group_tile?(html, "CalDAV servers", "ics_url")
      refute group_tile?(html, "Calendar subscriptions", "caldav")
    end

    @tag :capture_log
    test "submitting a feed URL persists the subscription and closes the modal", %{
      conn: conn,
      user: user
    } do
      stub_feed()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      subscribe(view)

      # The success flash is raised by the config component but rendered by the
      # parent LiveView, so `render_async/2` can return the component's own
      # re-render before the parent has painted the flash. Snapshotting once
      # makes this test position-dependent: it passes when earlier tests have
      # warmed the flow and fails when it runs first (seed 0). Poll instead.
      wait_until(fn -> render(view) =~ "Calendar integration added successfully" end)

      added = render(view)

      assert added =~ "Work calendar"
      refute has_element?(view, "#calendar-subscription-form")

      assert integration =
               Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "ics_url")

      assert integration.name == "Work calendar"

      assert_enqueued(
        worker: SyncIcsCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    @tag :capture_log
    test "the feed URL is stored encrypted and only its origin is left in the clear", %{
      conn: conn,
      user: user
    } do
      stub_feed()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      subscribe(view)

      integration =
        Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "ics_url")

      # The secret path must not survive anywhere readable on the row.
      assert integration.base_url == "https://outlook.office365.com"
      refute integration.base_url =~ "secret-token"
      refute to_string(integration.provider_account_id) =~ "secret-token"
      assert Encryption.decrypt(integration.subscription_url_encrypted) == @feed_url
    end

    @tag :capture_log
    test "the subscription's only calendar is read-only", %{conn: conn, user: user} do
      stub_feed()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      subscribe(view)

      integration =
        Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "ics_url")

      assert [calendar] = integration.calendar_list
      assert calendar.read_only
      assert Calendar.writable_calendars(integration.calendar_list) == []
    end

    @tag :capture_log
    test "a subscription is never promoted to the primary calendar", %{conn: conn, user: user} do
      stub_feed()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      subscribe(view)

      # Even as the user's first and only integration: a primary that cannot
      # receive a booking would break every booking write.
      assert {:error, _reason} = CalendarPrimary.get_primary_calendar_integration(user.id)
    end

    @tag :capture_log
    test "a subscription is never resolved as the booking integration", %{
      conn: conn,
      user: user
    } do
      stub_feed()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      subscribe(view)

      assert ClientManager.get_booking_integration_info(user.id) == {:error, :no_integration}
      assert ClientManager.booking_client(user.id) == nil
    end

    @tag :capture_log
    test "the connected row is marked read-only and hides controls that do not apply", %{
      conn: conn
    } do
      stub_feed()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      connected = subscribe(view)

      assert connected =~ "Read-only"

      # One synthetic calendar, always selected: there is nothing to manage.
      refute has_element?(view, "button[phx-click='manage_calendars']")

      # The CalDAV reconnect modal asks for credentials a subscription has not got.
      refute has_element?(view, "button[phx-click='show_reconnect']")
    end

    @tag :capture_log
    test "an unreachable feed is refused with an error rather than saved", %{
      conn: conn,
      user: user
    } do
      stub(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: "", headers: %{}}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      result = subscribe(view)

      refute result =~ "Calendar integration added successfully"
      refute Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "ics_url")
    end

    @tag :capture_log
    test "the same feed cannot be subscribed to twice", %{conn: conn, user: user} do
      stub_feed()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      subscribe(view)

      {:ok, second_view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      result = subscribe(second_view)

      assert result =~ "already exists"

      subscriptions =
        Enum.count(
          Repo.all(CalendarIntegrationSchema),
          &(&1.user_id == user.id and &1.provider == "ics_url")
        )

      assert subscriptions == 1
    end

    @tag :capture_log
    test "a genuine double submission is refused with a changeset error rather than a crash", %{
      user: user
    } do
      # Widens the gap between the duplicate check and the insert enough that
      # both concurrent submissions pass the check before either commits,
      # reproducing the race a double-submit (or two browser tabs) can hit.
      stub(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        Process.sleep(50)
        {:ok, %Req.Response{status: 200, body: @ics, headers: %{}}}
      end)

      params = %{"name" => "Race calendar", "url" => @feed_url}
      test_pid = self()

      results =
        [1, 2]
        |> Enum.map(fn _attempt ->
          Task.async(fn ->
            allow(Tymeslot.HTTPClientMock, test_pid, self())
            Calendar.create_subscription_with_validation(user.id, params)
          end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, _integration}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:changeset, _changeset}}, &1)) == 1

      subscriptions =
        Enum.count(
          Repo.all(CalendarIntegrationSchema),
          &(&1.user_id == user.id and &1.provider == "ics_url")
        )

      assert subscriptions == 1
    end
  end
end
