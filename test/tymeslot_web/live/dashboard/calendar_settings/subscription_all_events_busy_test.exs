defmodule TymeslotWeb.Dashboard.CalendarSettings.SubscriptionAllEventsBusyTest do
  @moduledoc """
  Counting every event of a subscribed calendar as busy, from the integrations
  dashboard: the checkbox when subscribing, and the toggle on an existing
  subscription's card.

  Holiday and school-holiday feeds mark their events free, so they would block
  no availability at all. The flag makes every event in the feed block.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :integrations
  @moduletag :calendar
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!
  setup :setup_dashboard_user

  @feed_url "https://feiertage.example.com/bw/feiertage.ics"

  @ics """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Example//Holidays//EN
  BEGIN:VEVENT
  UID:holiday@example.com
  DTSTART;VALUE=DATE:20261103
  DTEND;VALUE=DATE:20261104
  SUMMARY:Holiday
  TRANSP:TRANSPARENT
  END:VEVENT
  END:VCALENDAR
  """

  defp open_calendars(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")
    view
  end

  defp subscribe(view, extra) do
    stub(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: @ics, headers: %{}}}
    end)

    view
    |> element("button[phx-click='connect_provider'][phx-value-provider='ics_url']")
    |> render_click()

    view
    |> form("#calendar-subscription-form", %{
      "integration" => Map.merge(%{"name" => "Holidays BW", "url" => @feed_url}, extra)
    })
    |> render_submit()

    render_async(view, 5000)
  end

  defp subscription(user),
    do: Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "ics_url")

  describe "subscribing" do
    @tag :capture_log
    test "with the box ticked, the subscription counts every event as busy", %{
      conn: conn,
      user: user
    } do
      view = open_calendars(conn)
      subscribe(view, %{"all_events_busy" => "true"})

      wait_until(fn -> subscription(user) != nil end)
      assert subscription(user).all_events_busy
    end

    @tag :capture_log
    test "left unticked, the feed's own free and busy marks apply", %{conn: conn, user: user} do
      view = open_calendars(conn)
      subscribe(view, %{})

      wait_until(fn -> subscription(user) != nil end)
      refute subscription(user).all_events_busy
    end
  end

  describe "an existing subscription's card" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          name: "Holidays BW",
          provider: "ics_url",
          base_url: "https://feiertage.example.com",
          username_encrypted: nil,
          password_encrypted: nil,
          subscription_url_encrypted: Encryption.encrypt(@feed_url),
          calendar_list: [%{id: "subscription", name: "Subscribed calendar", selected: true}],
          is_active: true
        )

      %{integration: integration}
    end

    test "turns counting every event as busy on and off", %{
      conn: conn,
      integration: integration
    } do
      view = open_calendars(conn)
      toggle = "[data-testid='all-events-busy-toggle'][phx-value-id='#{integration.id}']"

      assert has_element?(view, "#{toggle}[aria-pressed='false']")
      refute render(view) =~ "every event blocks time"

      view |> element(toggle) |> render_click()

      assert Repo.reload!(integration).all_events_busy
      assert has_element?(view, "#{toggle}[aria-pressed='true']")
      assert render(view) =~ "every event blocks time, also those marked free"

      view |> element(toggle) |> render_click()

      refute Repo.reload!(integration).all_events_busy
      assert has_element?(view, "#{toggle}[aria-pressed='false']")
    end

    test "is not offered on a calendar that is not a subscription", %{conn: conn, user: user} do
      caldav = insert(:calendar_integration, user: user, provider: "caldav", is_active: true)
      view = open_calendars(conn)

      refute has_element?(
               view,
               "[data-testid='all-events-busy-toggle'][phx-value-id='#{caldav.id}']"
             )
    end
  end
end
