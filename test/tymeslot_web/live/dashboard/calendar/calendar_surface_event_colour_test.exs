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
  @moduletag :meetings

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
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
    target = {:external, integration.id, review.uid}
    {:ok, _override} = Calendar.set_event_colour(user.id, target, "tomato")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => id})

    assert has_element?(
             lv,
             "#calendar-panel-colour button[phx-value-colour='tomato'][aria-pressed='true']"
           )

    swatch(lv, "default")

    # Kept as cleared until the write-back has cleared the host.
    assert Calendar.overrides_for(user.id) == %{target => nil}
    refute pushed(lv, id).colour in ["calendar-tomato", "calendar-sage"]

    # The write-back still waiting with the old colour now clears it
    # instead, and nothing else is written.
    assert [%{args: %{"uid" => uid, "colour" => nil}}] =
             all_enqueued(worker: ColourWriteBackWorker)

    assert uid == review.uid
    refute_receive {:written, _uid, _payload}, 200
    refute has_element?(lv, "#calendar-undo")
  end

  test "Default on a member of a series asks no scope question", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    standup =
      event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
        recurring_event_id: "standup-series",
        colour: "sage"
      )

    {:ok, _override} =
      Calendar.set_event_colour(user.id, {:external, integration.id, standup.uid}, "tomato")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => "event-#{standup.id}"})
    swatch(lv, "default")

    refute has_element?(lv, "#calendar-series-scope")

    assert Calendar.overrides_for(user.id) == %{
             {:external, integration.id, standup.uid} => nil
           }

    assert [%{args: %{"colour" => nil}}] = all_enqueued(worker: ColourWriteBackWorker)
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

  test "a booking recoloured on the dashboard home shows that colour in the calendar", %{
    conn: conn,
    user: user
  } do
    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z]
      )

    plain =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        start_time: ~U[2026-10-15 12:00:00Z],
        end_time: ~U[2026-10-15 12:30:00Z]
      )

    {:ok, _override} = Calendar.set_event_colour(user.id, {:meeting, meeting.id}, "grape")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:ready", %{})
    assert_reply(lv, %{events: events})

    assert %{colour: "calendar-grape"} = Enum.find(events, &(&1.id == "booking-#{meeting.id}"))
    assert %{colour: "booking"} = Enum.find(events, &(&1.id == "booking-#{plain.id}"))

    hook(lv, "calendar:open", %{"id" => "booking-#{meeting.id}"})
    assert has_element?(lv, "#calendar-preview .cal-preview-swatch[style*='calendar-grape']")
  end

  test "a colour taken off stays off when the provider refuses the clear and a sync reads it back",
       %{conn: conn, user: user, integration: integration} do
    review =
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z], 60, colour: "sage")

    id = "event-#{review.id}"

    {:ok, _override} =
      Calendar.set_event_colour(user.id, {:external, integration.id, review.uid}, "tomato")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => id})
    swatch(lv, "default")

    Mox.stub(CalendarMock, :update_event, fn _uid, _payload, _context -> {:error, :forbidden} end)
    [clearing] = all_enqueued(worker: ColourWriteBackWorker)
    assert {:error, :forbidden} = perform_job(ColourWriteBackWorker, clearing.args)

    # The host still has the colour, so the next sync caches it again.
    {:ok, 1} =
      ProviderCalendarEventQueries.upsert_batch([
        review
        |> Map.take([
          :calendar_integration_id,
          :uid,
          :provider,
          :provider_event_id,
          :provider_calendar_id,
          :summary,
          :start_at,
          :end_at,
          :all_day,
          :sync_state
        ])
        |> Map.merge(%{colour: "sage", synced_at: DateTime.utc_now()})
      ])

    assert {:ok, %{colour: "sage"}} =
             ProviderCalendarEventQueries.get_by_uid(integration.id, review.uid)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => id})

    assert has_element?(
             lv,
             "#calendar-panel-colour button[phx-value-colour='default'][aria-pressed='true']"
           )
  end
end
