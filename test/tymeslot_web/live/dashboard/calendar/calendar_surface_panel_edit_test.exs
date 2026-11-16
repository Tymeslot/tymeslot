defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelEditTest do
  @moduledoc """
  The side panel's text and toggle fields: each change is written to the
  calendar as it is made, the header says how it went, and it can be undone;
  an unchanged value writes nothing, and a member of a repeating series asks
  which events once for the whole time the panel is open.
  """

  use TymeslotWeb.LiveCase, async: true

  import Tymeslot.Factory

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers
  import Phoenix.LiveView, only: [send_update: 3]

  alias Ecto.Changeset
  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.Reminder
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{lv: lv, review: review})
  end

  defp edit(lv, event) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{event.id}"})

    lv
  end

  defp status(lv),
    do:
      lv
      |> element("#calendar-panel-status")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.text()

  defp alarms(reminders),
    do: Enum.map(reminders, &{Reminder.method(&1), Reminder.minutes_before(&1)})

  test "a new title is written on blur, trimmed, and the header says it saved", %{
    lv: lv,
    review: review
  } do
    lv
    |> edit(review)
    |> element("#calendar-panel-title")
    |> render_blur(%{"value" => " Design sync "})

    uid = review.uid
    assert_receive {:written, ^uid, %{summary: "Design sync"}}
    eventually(fn -> assert status(lv) =~ "Saved" end)
    refute has_element?(lv, "#calendar-toast")
  end

  test "Enter in the place field writes it", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> element("#calendar-panel-location")
    |> render_keydown(%{"key" => "Enter", "value" => "Room 4"})

    uid = review.uid
    assert_receive {:written, ^uid, %{location: "Room 4"}}
  end

  test "notes are written on blur", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> element("#calendar-panel-notes")
    |> render_blur(%{"value" => "Bring the mock-ups"})

    uid = review.uid
    assert_receive {:written, ^uid, %{description: "Bring the mock-ups"}}
  end

  test "an unchanged value writes nothing", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> element("#calendar-panel-title")
    |> render_blur(%{"value" => "Design review"})

    refute_receive {:written, _uid, _payload}, 200
    assert status(lv) =~ "Changes save automatically"
  end

  test "a title too long for the calendar is refused in the field", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> element("#calendar-panel-title")
    |> render_blur(%{"value" => String.duplicate("a", 501)})

    assert has_element?(
             lv,
             "#calendar-panel",
             "The title is too long. Keep it under 500 characters."
           )

    refute_receive {:written, _uid, _payload}, 200
  end

  test "a blank title is refused in the field, as a create refuses it", %{
    lv: lv,
    review: review
  } do
    lv
    |> edit(review)
    |> element("#calendar-panel-title")
    |> render_blur(%{"value" => "   "})

    assert has_element?(lv, "#calendar-panel", "Give the event a title.")
    refute_receive {:written, _uid, _payload}, 200
  end

  test "Free is written as transparent", %{lv: lv, review: review} do
    lv |> edit(review) |> element("#calendar-panel-free-free") |> render_click()

    uid = review.uid
    assert_receive {:written, ^uid, %{transparency: "transparent"}}
  end

  describe "closing with a text field focused" do
    test "the title being typed is saved, then the panel closes", %{lv: lv, review: review} do
      edit(lv, review)
      assert has_element?(lv, "#calendar-panel-title[data-panel-field='title']")

      lv
      |> element("#calendar-canvas")
      |> render_hook("panel:close", %{"field" => "title", "value" => "Design sync"})

      uid = review.uid
      assert_receive {:written, ^uid, %{summary: "Design sync"}}
      refute has_element?(lv, "#calendar-panel")
    end

    test "the notes being typed are saved too", %{lv: lv, review: review} do
      edit(lv, review)

      lv
      |> element("#calendar-canvas")
      |> render_hook("panel:close", %{"field" => "notes", "value" => "Bring the mock-ups"})

      uid = review.uid
      assert_receive {:written, ^uid, %{description: "Bring the mock-ups"}}
      refute has_element?(lv, "#calendar-panel")
    end

    test "a value the field refuses keeps the panel open, saying why", %{lv: lv, review: review} do
      edit(lv, review)

      lv
      |> element("#calendar-canvas")
      |> render_hook("panel:close", %{"field" => "title", "value" => String.duplicate("a", 501)})

      assert has_element?(
               lv,
               "#calendar-panel",
               "The title is too long. Keep it under 500 characters."
             )

      refute_receive {:written, _uid, _payload}, 200
    end

    test "a refusal shown in the header keeps the panel open", %{
      conn: conn,
      integration: integration
    } do
      integration
      |> Changeset.change(
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true},
          %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
        ]
      )
      |> Repo.update!()

      shared = event(integration, "shared", "Team offsite", ~U[2026-10-16 09:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      edit(lv, shared)

      lv
      |> element("#calendar-canvas")
      |> render_hook("panel:close", %{"field" => "title", "value" => "Offsite"})

      assert has_element?(lv, "#calendar-panel")
      assert status(lv) =~ "Couldn't save"
      refute_receive {:written, _uid, _payload}, 200
    end
  end

  describe "Busy and Free on a booking's calendar copy" do
    test "a hand-crafted change writes nothing", %{
      conn: conn,
      integration: integration
    } do
      copy = event(integration, "work", "Intro call", ~U[2026-10-16 10:00:00Z])
      insert(:meeting, calendar_integration_id: integration.id, calendar_uid: copy.uid)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      edit(lv, copy)
      refute has_element?(lv, "#calendar-panel-free")

      lv |> element("#calendar-canvas") |> render_hook("panel:free", %{"value" => "free"})

      refute_receive {:written, _uid, _payload}, 200
    end
  end

  describe "the reminder" do
    setup %{conn: conn, integration: integration} do
      alarmed =
        event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z], 60,
          reminders: [
            %{"method" => "popup", "minutes_before" => 30},
            %{"method" => "email", "minutes_before" => 1440}
          ]
        )

      # The window is read on mount, so the page is opened after the event exists.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      %{alarmed: alarmed, lv: lv}
    end

    test "shows the notification and lists the other alarm", %{lv: lv, alarmed: alarmed} do
      edit(lv, alarmed)

      assert has_element?(lv, "#calendar-panel-reminder-choice option[value='30'][selected]")
      assert has_element?(lv, "#calendar-panel-other-reminders", "Email 1 day before")
    end

    test "a preset replaces the notification and keeps the other alarm", %{
      lv: lv,
      alarmed: alarmed
    } do
      lv
      |> edit(alarmed)
      |> element("#calendar-panel-reminder")
      |> render_change(%{"reminder" => "10"})

      uid = alarmed.uid
      assert_receive {:written, ^uid, payload}
      assert alarms(payload.reminders) == [{:popup, 10}, {:email, 1440}]
    end

    test "None keeps only the other alarm", %{lv: lv, alarmed: alarmed} do
      lv
      |> edit(alarmed)
      |> element("#calendar-panel-reminder")
      |> render_change(%{"reminder" => "none"})

      uid = alarmed.uid
      assert_receive {:written, ^uid, payload}
      assert alarms(payload.reminders) == [{:email, 1440}]
    end
  end

  test "undo takes a title change back", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> element("#calendar-panel-title")
    |> render_blur(%{"value" => "Design sync"})

    assert_receive {:written, _uid, %{summary: "Design sync"}}
    render(lv)

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    uid = review.uid
    assert_receive {:written, ^uid, %{summary: "Design review"}}, 1_000
    assert has_element?(lv, "#calendar-toast", "Change undone")
    # The panel, still open, shows the value the undo put back.
    assert has_element?(lv, "#calendar-panel-title[value='Design review']")
  end

  describe "a member of a repeating series" do
    setup %{conn: conn, integration: integration} do
      standup =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      %{standup: standup, lv: lv}
    end

    test "asks which events once, then keeps the answer", %{lv: lv, standup: standup} do
      lv
      |> edit(standup)
      |> element("#calendar-panel-title")
      |> render_blur(%{"value" => "Stand-up"})

      assert has_element?(lv, "#calendar-series-scope", "Standup")
      refute_received {:written, _uid, _payload}

      lv |> element("#calendar-scope-this_only") |> render_click()
      uid = standup.uid
      assert_receive {:written, ^uid, %{summary: "Stand-up"}}

      lv
      |> element("#calendar-panel-location")
      |> render_keydown(%{"key" => "Enter", "value" => "Room 4"})

      refute has_element?(lv, "#calendar-series-scope")
      assert_receive {:written, ^uid, %{location: "Room 4"}}
    end

    test "cancelling the question writes nothing", %{lv: lv, standup: standup} do
      lv
      |> edit(standup)
      |> element("#calendar-panel-title")
      |> render_blur(%{"value" => "Stand-up"})

      lv |> element("#calendar-series-scope button", "Cancel") |> render_click()

      refute has_element?(lv, "#calendar-series-scope")
      refute_receive {:written, _uid, _payload}, 200
    end
  end

  describe "when the surface revives with a write in flight" do
    setup do
      test_pid = self()

      Mox.stub(CalendarMock, :update_event, fn _uid, _payload, _context ->
        send(test_pid, {:writing, self()})

        receive do
          :release -> :ok
        end
      end)

      :ok
    end

    # The organiser left the calendar and came back before the browser
    # confirmed the surface's removal: the surface takes its queue back from
    # the guardian that drove it meanwhile, whose answers it never heard.
    defp revive(lv) do
      send_update(lv.pid, CalendarSurface, id: "calendar", calendar_left: 1)
      render(lv)
      render(lv)
    end

    test "the header stops saying Saving", %{lv: lv, review: review} do
      lv
      |> edit(review)
      |> element("#calendar-panel-title")
      |> render_blur(%{"value" => "Design sync"})

      assert_receive {:writing, writer}, 1_000
      on_exit(fn -> send(writer, :release) end)
      assert status(lv) =~ "Saving"

      revive(lv)

      refute status(lv) =~ "Saving"
    end

    test "the change is no longer on the undo stack", %{lv: lv, review: review} do
      lv
      |> edit(review)
      |> element("#calendar-panel-title")
      |> render_blur(%{"value" => "Design sync"})

      assert_receive {:writing, writer}, 1_000
      on_exit(fn -> send(writer, :release) end)

      revive(lv)
      lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

      assert has_element?(lv, "#calendar-toast", "Nothing to undo.")
    end
  end

  describe "when the write fails" do
    setup do
      Mox.stub(CalendarMock, :update_event, fn _uid, _payload, _context ->
        {:error, :provider_down}
      end)

      :ok
    end

    test "the header says so and the title goes back", %{lv: lv, review: review} do
      lv
      |> edit(review)
      |> element("#calendar-panel-title")
      |> render_blur(%{"value" => "Design sync"})

      eventually(fn -> assert status(lv) =~ "Couldn't save. The change was put back." end)
      assert has_element?(lv, "#calendar-panel-title[value='Design review']")
    end

    test "the change is no longer on the undo stack", %{lv: lv, review: review} do
      lv
      |> edit(review)
      |> element("#calendar-panel-title")
      |> render_blur(%{"value" => "Design sync"})

      eventually(fn -> assert status(lv) =~ "Couldn't save" end)

      lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

      assert has_element?(lv, "#calendar-toast", "Nothing to undo.")
    end
  end
end
