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

    render(view)
  end

  describe "subscribing to a feed" do
    @tag :capture_log
    test "the tile is filed under subscriptions, not under CalDAV servers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      assert html =~ "Calendar subscriptions"
    end

    @tag :capture_log
    test "submitting a feed URL persists the subscription and closes the modal", %{
      conn: conn,
      user: user
    } do
      stub_feed()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
      added = subscribe(view)

      assert added =~ "Calendar integration added successfully"
      assert added =~ "Work calendar"
      refute has_element?(view, "#calendar-subscription-form")

      assert integration =
               Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "ics_url")

      assert integration.name == "Work calendar"
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
  end
end
