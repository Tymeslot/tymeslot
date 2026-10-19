defmodule TymeslotWeb.Dashboard.CalendarSettings.RemovedCalendarsTest do
  @moduledoc """
  An owner whose calendar server stopped listing a calendar Tymeslot used
  sees it on the calendar's card and in the integrations banner, and
  dismisses the notice from the card: both go.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :calendar

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.RemovedCalendar
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup %{user: user} do
    RateLimiter.clear_all()

    integration =
      insert(:calendar_integration,
        user: user,
        name: "Home server",
        provider: "caldav",
        calendar_paths: ["/cal/"],
        removed_calendars: [
          %RemovedCalendar{id: "/old/", name: "Projects", removed_at: ~U[2026-10-01 08:00:00Z]}
        ]
      )

    %{integration: integration}
  end

  defp dismiss_button(view, integration),
    do:
      element(
        view,
        "button[phx-click='dismiss_removed_calendars'][phx-value-id='#{integration.id}']"
      )

  # Dismiss sits on the card whatever the connection's state, so what it
  # clears must be shown alongside the connection's own notice.
  test "an unhealthy integration shows its removed calendars beside its own notice", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    %IntegrationHealthStateSchema{}
    |> IntegrationHealthStateSchema.changeset(%{
      integration_type: "calendar",
      integration_id: integration.id,
      user_id: user.id,
      status: "unhealthy"
    })
    |> Repo.insert!()

    integration |> Changeset.change(sync_error: "Connection refused") |> Repo.update!()

    {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    # The banner leads with the worse problem, and counts the connection once.
    assert html =~ "1 connection needs attention - Home server stopped syncing."

    # The card shows both, one under the other, beside the Dismiss button.
    notices =
      view |> render() |> Floki.parse_document!() |> Floki.find("[data-part='notice']")

    assert Enum.map(notices, &Floki.text/1) |> Enum.map(&String.trim/1) |> Enum.at(-1) ==
             "“Projects” is no longer on your calendar server, so Tymeslot has stopped using it."

    assert length(notices) == 2
    assert has_element?(dismiss_button(view, integration))
  end

  test "the card and the banner name the calendar, and Dismiss clears both", %{
    conn: conn,
    integration: integration
  } do
    {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    assert html =~
             "“Projects” is no longer on your calendar server, so Tymeslot has stopped using it."

    assert html =~
             "Home server: “Projects” is no longer on your calendar server, so Tymeslot has stopped using it."

    view |> dismiss_button(integration) |> render_click()

    # The banner is the parent's, refreshed by the message the click sends it.
    refute render(view) =~ "is no longer on your calendar server"
    refute has_element?(dismiss_button(view, integration))
    assert Repo.get!(CalendarIntegrationSchema, integration.id).removed_calendars == []

    {:ok, _view, reloaded} = live(conn, ~p"/dashboard/integrations?tab=calendars")
    refute reloaded =~ "is no longer on your calendar server"
  end

  # The page rendered Projects; Team was recorded after, so the owner has
  # not seen it and Dismiss must leave it.
  test "Dismiss keeps a calendar recorded after the page rendered", %{
    conn: conn,
    integration: integration
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    integration
    |> Changeset.change()
    |> Changeset.put_embed(
      :removed_calendars,
      integration.removed_calendars ++
        [%RemovedCalendar{id: "/team/", name: "Team", removed_at: ~U[2026-10-01 09:00:00Z]}]
    )
    |> Repo.update!()

    view |> dismiss_button(integration) |> render_click()

    assert [%RemovedCalendar{id: "/team/"}] =
             Repo.get!(CalendarIntegrationSchema, integration.id).removed_calendars

    # Reloaded after the dismissal, the card now shows what is left.
    assert render(view) =~ "“Team” is no longer on your calendar server"
  end

  # The list comes back from the browser, so it may not be what the card sent.
  test "a shown list that is not a JSON list dismisses nothing", %{
    conn: conn,
    integration: integration
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    for shown <- ["not json", ~s({"id": "/old/"}), ~s("/old/"), ~s([1, null])] do
      view |> dismiss_button(integration) |> render_click(%{"shown" => shown})

      assert [%RemovedCalendar{id: "/old/"}] =
               Repo.get!(CalendarIntegrationSchema, integration.id).removed_calendars
    end

    assert render(view) =~ "“Projects” is no longer on your calendar server"
  end

  test "several calendars are counted and listed", %{conn: conn, integration: integration} do
    integration
    |> Changeset.change()
    |> Changeset.put_embed(:removed_calendars, [
      %RemovedCalendar{id: "/a/", name: "Projects", removed_at: ~U[2026-10-01 08:00:00Z]},
      %RemovedCalendar{id: "/b/", name: "Team", removed_at: ~U[2026-10-01 08:00:00Z]}
    ])
    |> Repo.update!()

    {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    assert html =~
             "2 calendars are no longer on your calendar server, so Tymeslot has stopped using them: “Projects”, “Team”"

    assert html =~
             "Home server: 2 calendars are no longer on your calendar server, so Tymeslot has stopped using them."
  end

  test "a calendar with nothing removed shows no notice and no Dismiss", %{
    conn: conn,
    integration: integration
  } do
    integration
    |> Changeset.change()
    |> Changeset.put_embed(:removed_calendars, [])
    |> Repo.update!()

    {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    refute html =~ "is no longer on your calendar server"
    refute has_element?(dismiss_button(view, integration))
  end
end
