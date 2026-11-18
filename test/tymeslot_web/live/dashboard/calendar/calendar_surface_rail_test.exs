defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceRailTest do
  @moduledoc """
  The calendar's rail: calendars grouped by account with colour
  checkboxes and a lock on calendars Tymeslot cannot write to, and the rule
  that filters never hide silently: with the rail collapsed, hidden calendars
  show as a removable chip in the toolbar.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Phoenix.HTML
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Security.RateLimiter

  setup %{conn: conn}, do: owner(conn)

  defp pushed_titles(lv) do
    assert_push_event(lv, "calendar:events", %{reset: true, events: events})
    Enum.map(events, & &1.title)
  end

  test "lists each account's calendars, ticked", %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-account-#{integration.id}", "Work account")
    assert has_element?(lv, "#calendar-rail [data-calendar-id='work'][aria-checked='true']")
    assert has_element?(lv, "#calendar-rail [data-calendar-id='family'][aria-checked='true']")
  end

  test "unticking a calendar hides its events, unticks it and remembers", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    event(integration, "family", "School run", ~U[2026-10-14 07:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()

    titles = pushed_titles(lv)
    assert "Design review" in titles
    refute "School run" in titles
    assert has_element?(lv, "#calendar-rail [data-calendar-id='family'][aria-checked='false']")
    assert {integration.id, "family"} in Appearance.hidden_keys(Appearance.list_for_user(user.id))
  end

  test "unticking an account hides every calendar in it", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-account-id='#{integration.id}']") |> render_click()

    assert pushed_titles(lv) == []

    assert CalendarPreferencesQueries.get_or_create(user.id).hidden_integration_ids == [
             integration.id
           ]
  end

  test "with the rail collapsed, hidden calendars show as a chip that brings them back",
       %{conn: conn, integration: integration} do
    event(integration, "family", "School run", ~U[2026-10-14 07:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
    _hidden = pushed_titles(lv)
    lv |> element("#calendar-rail-toggle") |> render_click()

    refute has_element?(lv, "#calendar-rail")
    assert has_element?(lv, "#calendar-filter-chip", "1 calendar hidden")

    lv |> element("#calendar-show-all") |> render_click()

    assert "School run" in pushed_titles(lv)
    refute has_element?(lv, "#calendar-filter-chip")
  end

  test "a calendar Tymeslot cannot write to carries a lock", %{conn: conn, user: user} do
    feed =
      insert(:calendar_integration,
        user: user,
        name: "Holidays",
        provider: "ics_url",
        is_active: true,
        calendar_list: [%{"id" => "feed", "name" => "Public holidays", "selected" => true}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-account-#{feed.id} [data-read-only] + [role='tooltip']",
             "Read only"
           )
  end

  test "an account id that is not the organiser's changes nothing", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:toggle_account", %{"integration-id" => "999999999"})

    assert CalendarPreferencesQueries.get_or_create(user.id).hidden_integration_ids == []
  end

  test "an event sent without the params it needs leaves the calendar running", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    canvas = element(lv, "#calendar-canvas")

    for event <- ~w(calendar:goto calendar:toggle_account calendar:sync_account calendar:no_such) do
      render_hook(canvas, event, %{})
    end

    render_hook(canvas, "calendar:goto", %{"view" => "week"})
    assert render_hook(canvas, "calendar:open", %{"id" => 42})
    assert render_hook(canvas, "calendar:open", %{})

    assert Process.alive?(lv.pid)
    assert has_element?(lv, "#calendar-canvas")
  end

  test "inside a hidden account the calendars keep their own ticks and cannot be toggled", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-account-id='#{integration.id}']") |> render_click()
    _hidden = pushed_titles(lv)

    assert has_element?(lv, "#calendar-rail [data-calendar-id='work'][aria-checked='true']")

    assert has_element?(
             lv,
             "#calendar-rail [data-calendar-id='work'][aria-disabled='true'][disabled]"
           )

    refute has_element?(lv, "#calendar-rail [data-calendar-id='work'][phx-click]")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:toggle_calendar", %{
      "integration-id" => to_string(integration.id),
      "calendar-id" => "work"
    })

    refute_push_event(lv, "calendar:events", _payload)
    appearances = Appearance.list_for_user(user.id)
    assert Enum.reject(appearances, &(&1.hidden == false)) == []
    assert Appearance.hidden_keys(appearances) == MapSet.new()
  end

  test "a calendar id on an account that is not the organiser's changes nothing", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:toggle_calendar", %{
      "integration-id" => "999999999",
      "calendar-id" => "work"
    })

    refute_push_event(lv, "calendar:events", _payload)
    assert Appearance.list_for_user(user.id) == []
  end

  test "toggling past the rate limit shows the warning and changes nothing", %{
    conn: conn,
    user: user
  } do
    message = exhaust_visibility_budget(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()

    assert render(lv) =~ escaped(message)
    refute_push_event(lv, "calendar:events", _payload)
    assert Appearance.hidden_keys(Appearance.list_for_user(user.id)) == MapSet.new()
    assert has_element?(lv, "#calendar-rail [data-calendar-id='family'][aria-checked='true']")
  end

  test "toggling an account past the rate limit shows the warning and changes nothing", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    message = exhaust_visibility_budget(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-rail [data-account-id='#{integration.id}']") |> render_click()

    assert render(lv) =~ escaped(message)
    refute_push_event(lv, "calendar:events", _payload)
    assert CalendarPreferencesQueries.get_or_create(user.id).hidden_integration_ids == []
  end

  defp exhaust_visibility_budget(user) do
    {:error, :rate_limited, message} =
      Enum.find(
        Stream.repeatedly(fn -> RateLimiter.check(:calendar_visibility, user.id) end),
        &match?({:error, :rate_limited, _message}, &1)
      )

    message
  end

  defp escaped(message), do: message |> HTML.html_escape() |> HTML.safe_to_string()

  test "showing everything clears a hidden account as well as hidden calendars", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    event(integration, "family", "School run", ~U[2026-10-14 07:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
    _titles = pushed_titles(lv)
    lv |> element("#calendar-rail [data-account-id='#{integration.id}']") |> render_click()
    assert pushed_titles(lv) == []

    lv |> element("#calendar-show-all") |> render_click()

    assert Enum.sort(pushed_titles(lv)) == ["Design review", "School run"]

    assert CalendarPreferencesQueries.get_or_create(user.id).hidden_integration_ids == []
    assert Appearance.hidden_keys(Appearance.list_for_user(user.id)) == MapSet.new()
  end

  describe "a calendar that does not block bookings" do
    setup %{user: user} do
      personal =
        insert(:calendar_integration,
          user: user,
          name: "Personal",
          provider: "google",
          is_active: true,
          calendar_list: [
            %{"id" => "diary", "name" => "Diary", "selected" => true},
            %{
              "id" => "holidays",
              "name" => "Holidays",
              "selected" => true,
              "blocks_availability" => false
            }
          ]
        )

      %{personal: personal}
    end

    test "is marked in the rail, the marker named by its words", %{
      conn: conn,
      personal: personal
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      holidays = ~s|#calendar-account-#{personal.id} li[data-calendar-row="holidays"]|
      diary = ~s|#calendar-account-#{personal.id} li[data-calendar-row="diary"]|

      assert has_element?(
               lv,
               "#{holidays} [data-not-blocking] + [role='tooltip']",
               "Doesn't block"
             )

      assert has_element?(lv, "#{holidays} [data-not-blocking] .sr-only", "Doesn't block")
      refute has_element?(lv, "#{diary} [data-not-blocking]")
    end

    test "the calendar's checkbox is described by the marker; a blocking one is not", %{
      conn: conn,
      personal: personal
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      row = ~s|#calendar-account-#{personal.id} li[data-calendar-row="holidays"]|
      marker_id = "calendar-calendar-#{personal.id}-holidays-not-blocking"

      assert has_element?(lv, ~s|#{row} [role="checkbox"][aria-describedby="#{marker_id}"]|)
      assert has_element?(lv, "##{marker_id}", "Doesn't block")

      refute has_element?(
               lv,
               ~s|#calendar-account-#{personal.id} li[data-calendar-row="diary"] [aria-describedby]|
             )
    end

    test "the phone's Calendars sheet spells the marker out", %{conn: conn, personal: personal} do
      {:ok, lv, _html} =
        live(put_connect_params(conn, %{"viewport" => "phone"}), ~p"/dashboard/calendar")

      lv |> element("#calendar-phone-calendars") |> render_click()

      holidays = ~s|#calendar-sheet-account-#{personal.id} li[data-calendar-row="holidays"]|
      diary = ~s|#calendar-sheet-account-#{personal.id} li[data-calendar-row="diary"]|

      assert has_element?(lv, "#{holidays} [data-not-blocking]", "Doesn't block")
      refute has_element?(lv, "#{holidays} [data-not-blocking] .sr-only")
      refute has_element?(lv, "#{diary} [data-not-blocking]")
    end
  end

  describe "an Exchange mailbox's calendars" do
    test "the main calendar is unmarked and a folder is marked", %{conn: conn, user: user} do
      mailbox =
        insert(:calendar_integration,
          user: user,
          name: "Mailbox",
          provider: "exchange",
          is_active: true,
          calendar_list: [
            %{"id" => "main", "name" => "Calendar", "selected" => true, "primary" => true},
            %{"id" => "team", "name" => "Team", "selected" => true}
          ]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      account = "#calendar-account-#{mailbox.id}"

      refute has_element?(lv, ~s|#{account} li[data-calendar-row="main"] [data-not-blocking]|)
      assert has_element?(lv, ~s|#{account} li[data-calendar-row="team"] [data-not-blocking]|)
    end
  end
end
