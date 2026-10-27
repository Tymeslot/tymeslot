defmodule TymeslotWeb.Dashboard.CalendarSettings.CalendarBlockingTest do
  @moduledoc """
  Choosing, per calendar, whether Tymeslot uses it and whether its busy time
  blocks the booking page: the "Manage calendars" modal's controls, the
  subscription row's, the subscription form's, and the grid panel's marker
  for a calendar that is shown but does not block. Runs with `async: false`
  because every choice draws on the shared integration-write rate limiter.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :calendar

  import Mox
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarGrid.Header.CalendarListPanel

  setup :verify_on_exit!
  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp open_manage_modal(conn, integration) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    view
    |> element("button[phx-click='manage_calendars'][phx-value-id='#{integration.id}']")
    |> render_click()

    view
  end

  defp entry(integration, user, calendar_id) do
    {:ok, reloaded} = Calendar.get_integration(integration.id, user.id)
    Enum.find(reloaded.calendar_list, &(&1.id == calendar_id))
  end

  defp option(view, index, control, value),
    do: element(view, "#calendar-selection-calendar-#{index}-#{control}-#{value}")

  defp google(user, calendar_list, attrs \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge([user: user, provider: "google", calendar_list: calendar_list], attrs)
    )
  end

  describe "a calendar's use in the modal" do
    test "moves between off, show only and show and block", %{conn: conn, user: user} do
      integration =
        google(
          user,
          [%{id: "work", primary: true, selected: true}, %{id: "team", selected: true}],
          default_booking_calendar_id: "work"
        )

      view = open_manage_modal(conn, integration)

      render_click(option(view, 1, "state", "show"))
      assert %{selected: true, blocks_availability: false} = entry(integration, user, "team")

      render_click(option(view, 1, "state", "off"))
      assert %{selected: false} = entry(integration, user, "team")

      render_click(option(view, 1, "state", "block"))
      assert %{selected: true, blocks_availability: true} = entry(integration, user, "team")
    end

    test "counts the calendars in use and those that block", %{conn: conn, user: user} do
      integration =
        google(user, [
          %{id: "work", primary: true, selected: true},
          %{id: "holidays", selected: true, blocks_availability: false},
          %{id: "old", selected: false}
        ])

      view = open_manage_modal(conn, integration)

      assert view |> element("#calendar-selection-count") |> render() =~
               "2 of 3 calendars in use, 1 blocking your availability"
    end

    test "keeps the booking calendar showing and blocking", %{conn: conn, user: user} do
      integration =
        google(
          user,
          [%{id: "work", primary: true, selected: true}, %{id: "team", selected: true}],
          default_booking_calendar_id: "work"
        )

      view = open_manage_modal(conn, integration)

      assert has_element?(view, "#calendar-selection-calendar-0-state-off[disabled]")
      assert has_element?(view, "#calendar-selection-calendar-0-state-show[disabled]")
      assert has_element?(view, "#calendar-selection-calendar-0", "Booking calendar")

      assert has_element?(
               view,
               "#calendar-selection-calendar-0",
               "always blocks your availability"
             )

      # The refusal stands without the disabled buttons: the enabled option,
      # its pushed value overridden as a hand-crafted client would, is refused
      # by the context.
      view
      |> option(0, "state", "block")
      |> render_click(%{"state" => "show"})

      assert %{selected: true, blocks_availability: true} = entry(integration, user, "work")
      assert has_element?(view, "[role='alert']", "always blocks your availability")
    end

    test "offers a calendar shared as busy times only off or block", %{conn: conn, user: user} do
      integration =
        google(user, [
          %{id: "work", primary: true, selected: true},
          %{id: "boss", read_only: true, free_busy_only: true}
        ])

      view = open_manage_modal(conn, integration)

      refute has_element?(view, "#calendar-selection-calendar-1-state-show")
      assert has_element?(view, "#calendar-selection-calendar-1", "Busy times only")

      render_click(option(view, 1, "state", "block"))
      assert %{selected: true, blocks_availability: true} = entry(integration, user, "boss")
    end
  end

  describe "an Exchange mailbox in the modal" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "exchange",
          # Bookings go to the team folder, which cannot block; the main
          # calendar is then the owner's to set.
          default_booking_calendar_id: "team",
          calendar_list: [
            %{id: "main", name: "Calendar", primary: true, selected: true},
            %{id: "team", name: "Team", selected: true}
          ]
        )

      %{integration: integration}
    end

    test "chooses the main calendar's blocking apart from whether it is shown",
         %{conn: conn, user: user, integration: integration} do
      view = open_manage_modal(conn, integration)

      render_click(option(view, 0, "busy", "false"))
      assert %{selected: true, blocks_availability: false} = entry(integration, user, "main")

      render_click(option(view, 0, "shown", "false"))
      render_click(option(view, 0, "busy", "true"))
      assert %{selected: false, blocks_availability: true} = entry(integration, user, "main")

      assert has_element?(view, "#calendar-selection-calendar-0", "whole mailbox")
    end

    test "offers another folder off or show only, never block", %{
      conn: conn,
      integration: integration
    } do
      view = open_manage_modal(conn, integration)

      assert has_element?(view, "#calendar-selection-calendar-1-state-show")
      refute has_element?(view, "#calendar-selection-calendar-1-state-block")
      assert has_element?(view, "#calendar-selection-calendar-1", "main calendar only")
    end
  end

  describe "an Exchange mailbox that lists no main calendar" do
    # Its busy time is read for the whole mailbox and blocks; the screen must
    # say so rather than show every folder as not blocking.
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "exchange",
          calendar_list: [
            %{id: "team", name: "Team", selected: true},
            %{id: "rota", name: "Rota", selected: false}
          ]
        )

      %{integration: integration}
    end

    test "is shown as blocking, as one mailbox", %{conn: conn, integration: integration} do
      view = open_manage_modal(conn, integration)

      assert has_element?(view, "#calendar-selection-mailbox", "Busy times block")
      assert has_element?(view, "#calendar-selection-count", "1 blocking your availability")
      assert has_element?(view, "#calendar-selection-calendar-0", "whole mailbox")
      refute has_element?(view, "#calendar-selection-calendar-0", "main calendar only")
    end

    test "has no folder marked as not blocking on the grid", %{
      user: user,
      integration: integration
    } do
      {:ok, integration} = Calendar.get_integration(integration.id, user.id)

      html =
        render_component(&CalendarListPanel.calendar_list_panel/1,
          integrations: [integration],
          integration_colors: %{},
          calendar_colour_keys: %{},
          hidden_integration_ids: [],
          hidden_calendar_keys: MapSet.new(),
          myself: nil
        )

      refute html =~ "Doesn't block"
    end
  end

  describe "each control's accessible name" do
    test "names the calendar it sets", %{conn: conn, user: user} do
      integration = google(user, [%{id: "work", name: "Work", primary: true, selected: true}])
      view = open_manage_modal(conn, integration)

      assert has_element?(view, "#calendar-selection-calendar-0-state[aria-label='Use of Work']")
    end

    test "names the calendar on an Exchange main calendar's two controls",
         %{conn: conn, user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "exchange",
          calendar_list: [%{id: "main", name: "Calendar", primary: true, selected: true}]
        )

      view = open_manage_modal(conn, integration)

      assert has_element?(
               view,
               "#calendar-selection-calendar-0-shown[aria-label='Show Calendar on your calendar']"
             )

      assert has_element?(
               view,
               "#calendar-selection-calendar-0-busy[aria-label='Busy times of Calendar']"
             )
    end
  end

  describe "a booking calendar named in another encoding" do
    test "is still locked to show and block", %{conn: conn, user: user} do
      # A meeting type books into it under its decoded name.
      integration =
        google(
          user,
          [
            %{id: "work", name: "Work", primary: true, selected: true},
            %{id: "team%40example.org", name: "Team", selected: true}
          ],
          default_booking_calendar_id: "work"
        )

      insert(:meeting_type,
        user: user,
        calendar_integration_id: integration.id,
        target_calendar_id: "team@example.org"
      )

      view = open_manage_modal(conn, integration)

      assert has_element?(view, "#calendar-selection-calendar-1-state-show[disabled]")
    end
  end

  describe "a hand-crafted push the controls never send" do
    # A real control, its pushed values overridden as a hand-crafted client
    # would, so the push meets the same handler and context a click does.
    defp crafted_click(view, selector, params),
      do: view |> element(selector) |> render_click(params)

    defp exchange(user, list \\ nil) do
      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        calendar_list:
          list ||
            [
              %{id: "main", primary: true, selected: true},
              %{id: "team", selected: true, blocks_availability: false}
            ]
      )
    end

    test "cannot hide another provider's booking calendar through the Exchange-only switch",
         %{conn: conn, user: user} do
      google =
        google(user, [%{id: "work", primary: true, selected: true}],
          default_booking_calendar_id: "work"
        )

      view = open_manage_modal(conn, exchange(user))

      crafted_click(view, "#calendar-selection-calendar-0-shown-false", %{
        "integration_id" => to_string(google.id),
        "calendar_id" => "work"
      })

      assert %{selected: true, blocks_availability: true} = entry(google, user, "work")
    end

    test "cannot make an Exchange folder other than the main calendar block",
         %{conn: conn, user: user} do
      integration = exchange(user)
      view = open_manage_modal(conn, integration)

      crafted_click(view, "#calendar-selection-calendar-1-state-show", %{"state" => "block"})

      crafted_click(view, "#calendar-selection-calendar-0-busy-true", %{"calendar_id" => "team"})

      assert %{blocks_availability: false} = entry(integration, user, "team")
    end

    test "cannot set a calendar shared as busy times only to show without blocking",
         %{conn: conn, user: user} do
      integration =
        google(user, [
          %{id: "work", primary: true, selected: true},
          %{id: "boss", selected: true, read_only: true, free_busy_only: true}
        ])

      view = open_manage_modal(conn, exchange(user))

      crafted_click(view, "#calendar-selection-calendar-0-busy-true", %{
        "integration_id" => to_string(integration.id),
        "calendar_id" => "boss",
        "blocks" => "false"
      })

      assert %{selected: true, blocks_availability: true} = entry(integration, user, "boss")
    end
  end

  describe "a subscription" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "ics_url",
          calendar_list: [%{id: "subscription", selected: true, read_only: true}]
        )

      %{integration: integration}
    end

    test "is set not to block, and to block again, from its row",
         %{conn: conn, user: user, integration: integration} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view |> element("#calendar-#{integration.id}-feed-busy-false") |> render_click()
      assert %{blocks_availability: false} = entry(integration, user, "subscription")

      view |> element("#calendar-#{integration.id}-feed-busy-true") |> render_click()
      assert %{blocks_availability: true} = entry(integration, user, "subscription")
    end
  end

  describe "the grid's calendar panel" do
    test "marks a shown calendar that does not block", %{user: user} do
      integration =
        google(user, [
          %{id: "work", name: "Work", selected: true},
          %{id: "holidays", name: "Holidays", selected: true, blocks_availability: false}
        ])

      {:ok, integration} = Calendar.get_integration(integration.id, user.id)

      html =
        render_component(&CalendarListPanel.calendar_list_panel/1,
          integrations: [integration],
          integration_colors: %{},
          calendar_colour_keys: %{},
          hidden_integration_ids: [],
          hidden_calendar_keys: MapSet.new(),
          myself: nil
        )

      [work, holidays] = html |> Floki.parse_fragment!() |> Floki.find("label") |> tl()

      refute Floki.text(work) =~ "Doesn't block"
      assert Floki.text(holidays) =~ "Doesn't block"
    end
  end
end
