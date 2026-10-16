defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceRefreshTest do
  @moduledoc """
  The new calendar keeps up with changes made elsewhere: a sync that brings
  new events, an event deleted at the provider, or a calendar added to an
  account, redraws the grid and the rail without a reload.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Repo

  setup %{conn: conn}, do: owner(conn)

  # The first load is handed to the hook in the page itself, so the only
  # `calendar:events` push a test sees is the refresh.
  defp mounted(conn) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv
  end

  test "new events from a sync reach the grid", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    lv = mounted(conn)
    event(integration, "work", "Synced just now", ~U[2026-10-15 09:00:00Z])

    send(lv.pid, {:calendar_events_updated, user.id, []})

    assert_push_event(lv, "calendar:events", %{reset: true, events: events})
    assert Enum.any?(events, &(&1.title == "Synced just now"))
  end

  test "an event deleted elsewhere leaves the grid", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    gone = event(integration, "work", "Cancelled upstream", ~U[2026-10-15 09:00:00Z])
    lv = mounted(conn)

    Repo.delete!(gone)
    send(lv.pid, {:calendar_events_updated, user.id, []})

    assert_push_event(lv, "calendar:events", %{reset: true, events: events})
    refute Enum.any?(events, &(&1.title == "Cancelled upstream"))
  end

  test "a calendar added to an account appears in the rail after its sync", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    lv = mounted(conn)

    integration
    |> Ecto.Changeset.change(
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true},
        %{"id" => "family", "name" => "Family", "selected" => true},
        %{"id" => "travel", "name" => "Travel", "selected" => true}
      ]
    )
    |> Repo.update!()

    send(lv.pid, {:calendar_sync_complete, user.id, integration.id})

    assert_push_event(lv, "calendar:events", %{reset: true})
    assert has_element?(lv, "#calendar-rail [data-calendar-id='travel']")
  end
end
