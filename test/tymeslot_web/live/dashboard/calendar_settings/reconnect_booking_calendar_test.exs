defmodule TymeslotWeb.Dashboard.CalendarSettings.ReconnectBookingCalendarTest do
  @moduledoc """
  The CalDAV reconnect form and what decides whether a calendar blocks: a
  booking calendar's box comes up ticked and locked, as in the calendar
  settings, and the save keeps it selected and blocking whatever the request
  names; any other calendar keeps the owner's choice as it stands when the
  form is saved, not as it was when the form opened. Discovery runs over the
  real HTTP client against `Tymeslot.Test.CalDAVDiscoveryStub`, hence
  `async: false`.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :integrations
  @moduletag :calendar

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.ProviderBreakers
  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.CalDAVDiscoveryStub

  @base_url "http://localhost:65432"

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    with_config(:tymeslot, :allow_private_ips_for_calendar, true)
    CalendarCircuitBreaker.reset(:caldav)
    CalendarCircuitBreaker.reset(:caldav, ProviderBreakers.host_from_base_url(@base_url))
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user

  test "a booking calendar's box is locked ticked, and saving keeps it blocking",
       %{conn: conn, user: user} do
    integration =
      insert(:calendar_integration,
        user: user,
        name: "Bypass CalDAV",
        provider: "caldav",
        base_url: @base_url,
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("oldpass"),
        provider_account_id: "#{@base_url}||alice",
        is_active: true,
        needs_reauth: true,
        calendar_paths: ["/calendars/alice/default/", "/calendars/alice/work/"],
        default_booking_calendar_id: "/calendars/alice/default/",
        calendar_list: [
          %{id: "/calendars/alice/default/", path: "/calendars/alice/default/", selected: true},
          %{
            id: "/calendars/alice/work/",
            path: "/calendars/alice/work/",
            selected: true,
            blocks_availability: false
          }
        ]
      )

    insert(:meeting_type,
      user: user,
      calendar_integration_id: integration.id,
      target_calendar_id: "/calendars/alice/work/"
    )

    CalDAVDiscoveryStub.stub("alice:oldpass", "/principals/alice/", "/calendars/alice/", [
      {"/calendars/alice/default/", "Default"},
      {"/calendars/alice/work/", "Work"}
    ])

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    view
    |> element("button[phx-click='show_reconnect'][phx-value-id='#{integration.id}']")
    |> render_click()

    view
    |> form("form[phx-submit='reconnect_caldav_discover']",
      reconnect: %{url: integration.base_url, username: "alice", password: "oldpass"}
    )
    |> render_submit()

    assert has_element?(
             view,
             "input[type=checkbox][checked][disabled][value='/calendars/alice/work/']"
           )

    assert has_element?(view, "input[type=hidden][value='/calendars/alice/work/']")

    # A request naming the other calendar alone, as a forged one could.
    view
    |> element("form[phx-submit='reconnect_caldav_submit']")
    |> render_submit(%{"selected_paths" => ["/calendars/alice/default/"]})

    reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)

    assert %{selected: true, blocks_availability: true} =
             Enum.find(reloaded.calendar_list, &(&1.path == "/calendars/alice/work/"))
  end

  test "a blocking choice changed while the form is open is kept", %{conn: conn, user: user} do
    integration =
      insert(:calendar_integration,
        user: user,
        name: "Bypass CalDAV",
        provider: "caldav",
        base_url: @base_url,
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("oldpass"),
        provider_account_id: "#{@base_url}||alice",
        is_active: true,
        calendar_paths: ["/calendars/alice/default/", "/calendars/alice/work/"],
        default_booking_calendar_id: "/calendars/alice/default/",
        calendar_list: [
          %{id: "/calendars/alice/default/", path: "/calendars/alice/default/", selected: true},
          %{id: "/calendars/alice/work/", path: "/calendars/alice/work/", selected: true}
        ]
      )

    CalDAVDiscoveryStub.stub("alice:oldpass", "/principals/alice/", "/calendars/alice/", [
      {"/calendars/alice/default/", "Default"},
      {"/calendars/alice/work/", "Work"}
    ])

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    view
    |> element("button[phx-click='show_reconnect'][phx-value-id='#{integration.id}']")
    |> render_click()

    view
    |> form("form[phx-submit='reconnect_caldav_discover']",
      reconnect: %{url: integration.base_url, username: "alice", password: "oldpass"}
    )
    |> render_submit()

    # From another tab, while this form waits to be saved.
    {:ok, _updated} = Blocking.set(integration, "/calendars/alice/work/", false)

    view
    |> element("form[phx-submit='reconnect_caldav_submit']")
    |> render_submit(%{
      "selected_paths" => ["/calendars/alice/default/", "/calendars/alice/work/"]
    })

    reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)

    assert %{selected: true, blocks_availability: false} =
             Enum.find(reloaded.calendar_list, &(&1.path == "/calendars/alice/work/"))
  end
end
