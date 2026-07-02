defmodule TymeslotWeb.Dashboard.DashboardAgendaColourTest do
  @moduledoc """
  End-to-end journey for setting a per-event colour from the dashboard agenda:
  open an event's detail modal, pick a colour, and see it persist as a durable
  override and render on the agenda.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :calendar

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp all_day_event(user, uid) do
    today = Date.utc_today()
    integration = insert(:calendar_integration, user: user)

    insert(:provider_calendar_event,
      calendar_integration: integration,
      summary: "Company offsite",
      uid: uid,
      all_day: true,
      start_date: today,
      end_date: Date.add(today, 1),
      start_at: nil,
      end_at: nil
    )

    integration
  end

  test "user colours an agenda event and it persists", %{conn: conn, user: user} do
    integration = all_day_event(user, "uid-colour-journey")

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Open the event's detail modal from its all-day pill.
    view |> element("button", "Company offsite") |> render_click()

    # Pick "blueberry" from the colour swatches.
    html =
      view
      |> element(~s{button[phx-click="set_entry_colour"][phx-value-colour="blueberry"]})
      |> render_click()

    # Persisted as a durable override, keyed on the stable (integration, uid).
    assert Calendar.overrides_for(user.id) ==
             %{{:external, integration.id, "uid-colour-journey"} => "blueberry"}

    # And the agenda re-renders in that palette colour (blueberry → bg-calendar-2).
    assert html =~ "bg-calendar-2"
  end

  test "user clears a colour override", %{conn: conn, user: user} do
    integration = all_day_event(user, "uid-colour-clear")

    {:ok, _} =
      Calendar.set_event_colour(
        user.id,
        {:external, integration.id, "uid-colour-clear"},
        "blueberry"
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view |> element("button", "Company offsite") |> render_click()
    view |> element(~s{button[phx-click="clear_entry_colour"]}) |> render_click()

    assert Calendar.overrides_for(user.id) == %{}
  end
end
