defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceEventColourTest do
  @moduledoc """
  Recolouring one event from the side panel: a swatch keeps the organiser's
  colour on the event and repaints it at once, written back to a provider
  that has a per-event colour; "Default colour" takes the event back to its
  calendar's colour, clearing the provider's too. An event the organiser
  cannot change offers no colour, and a colour sent for it is refused.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Workers.ColourWriteBackWorker

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    context
  end

  defp hook(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  defp pushed(lv, id) do
    assert_push_event(lv, "calendar:events", %{events: events})
    Enum.find(events, &(&1.id == id))
  end

  defp swatch(lv, colour),
    do:
      lv
      |> element("#calendar-panel-colour button[phx-value-colour='#{colour}']")
      |> render_click()

  test "a swatch keeps the colour, repaints the event and writes it back", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    id = "event-#{review.id}"
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => id})

    assert has_element?(
             lv,
             "#calendar-panel-colour button[phx-value-colour='default'][aria-pressed='true']"
           )

    swatch(lv, "tomato")

    assert %{colour: "calendar-tomato"} = pushed(lv, id)

    assert Calendar.overrides_for(user.id) == %{
             {:external, integration.id, review.uid} => "tomato"
           }

    assert_enqueued(
      worker: ColourWriteBackWorker,
      args: %{"uid" => review.uid, "colour" => "tomato", "integration_id" => integration.id}
    )

    assert has_element?(
             lv,
             "#calendar-panel-colour button[phx-value-colour='tomato'][aria-pressed='true']"
           )
  end

  test "Default takes the event back to its calendar's colour, the provider's included", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    review =
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z], 60, colour: "sage")

    id = "event-#{review.id}"

    {:ok, _override} =
      Calendar.set_event_colour(user.id, {:external, integration.id, review.uid}, "tomato")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => id})

    assert has_element?(
             lv,
             "#calendar-panel-colour button[phx-value-colour='tomato'][aria-pressed='true']"
           )

    swatch(lv, "default")

    assert Calendar.overrides_for(user.id) == %{}
    uid = review.uid
    assert_receive {:written, ^uid, %{colour: nil}}, 1_000
  end

  test "an event on a read-only calendar offers no colour, and one sent anyway is refused", %{
    conn: conn,
    user: user
  } do
    shared =
      insert(:calendar_integration,
        user: user,
        name: "Shared",
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "team", "name" => "Team", "selected" => true, "read_only" => true}
        ]
      )

    standup = event(shared, "team", "Stand-up", ~U[2026-10-14 10:00:00Z], 15)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => "event-#{standup.id}"})

    refute has_element?(lv, "#calendar-panel-colour")

    hook(lv, "panel:colour", %{"colour" => "tomato"})

    assert Calendar.overrides_for(user.id) == %{}
  end
end
