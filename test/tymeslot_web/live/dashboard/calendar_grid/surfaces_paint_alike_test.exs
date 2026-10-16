defmodule TymeslotWeb.Dashboard.CalendarGrid.SurfacesPaintAlikeTest do
  @moduledoc """
  The old grid and the redesigned surface paint one calendar in one colour.

  An account's second calendar, with no colour chosen, takes a spare rotation
  colour rather than the account's. Both surfaces must agree on it, or an
  organiser switching between them sees the same calendar change colour.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  setup %{conn: conn}, do: owner(conn, redesign_enabled: false)

  defp old_grid_classes(html, summary) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[id^='event-']")
    |> Enum.filter(&(Floki.text(&1) =~ summary))
    |> Floki.attribute("class")
    |> Enum.join(" ")
  end

  test "an account's second calendar takes the same spare colour on both surfaces", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    event(integration, "work", "Standup", ~U[2026-10-14 10:00:00Z])
    event(integration, "family", "Family dinner", ~U[2026-10-14 12:00:00Z])

    {:ok, old, _html} = live(conn, ~p"/dashboard/calendar")
    old_html = render(old)

    # The account rotates to the first slot; its second calendar takes the
    # next one nothing paints with.
    assert old_grid_classes(old_html, "Standup") =~ "bg-calendar-1"
    assert old_grid_classes(old_html, "Family dinner") =~ "bg-calendar-2"

    {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{redesign_enabled: true})
    {:ok, new, _html} = live(conn, ~p"/dashboard/calendar")

    new |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(new, %{events: events})
    colours = Map.new(events, &{&1.title, &1.colour})

    assert colours["Standup"] == "calendar-1"
    assert colours["Family dinner"] == "calendar-2"
  end
end
