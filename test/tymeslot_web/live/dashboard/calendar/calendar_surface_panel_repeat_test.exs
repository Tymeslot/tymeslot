defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelRepeatTest do
  @moduledoc """
  The side panel's Repeat field: presets named for the event's start, the
  summary of what is set, a custom pattern behind Custom…, what a calendar
  would refuse said before anything is written, and a series' rule changed
  for this and the following events or all of them, never removed.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    # Wednesday 14 October 2026, the month's second Wednesday.
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

  defp choose(lv, preset),
    do: lv |> element("#calendar-panel-repeat") |> render_change(%{"preset" => preset})

  defp status(lv) do
    lv
    |> element("#calendar-panel-status")
    |> render()
    |> String.replace("&#39;", "'")
  end

  test "offers presets named for the event's start", %{lv: lv, review: review} do
    edit(lv, review)

    for label <- [
          "Does not repeat",
          "Every day",
          "Every weekday",
          "Every week on Wednesday",
          "Every month on the second Wednesday",
          "Every year on 14 October",
          "Custom…"
        ] do
      assert has_element?(lv, "#calendar-panel-repeat-preset option", label)
    end

    assert has_element?(lv, "#calendar-panel-repeat-preset option[value='none'][selected]")
  end

  test "a preset is written as the event's rule and summed up", %{lv: lv, review: review} do
    lv |> edit(review) |> choose("weekly")

    uid = review.uid
    assert_receive {:written, ^uid, %{recurrence_rule: "FREQ=WEEKLY"}}
    assert has_element?(lv, "#calendar-panel-repeat-summary", "Repeats weekly")
    assert has_element?(lv, "#calendar-panel-repeat-preset option[value='weekly'][selected]")
  end

  test "the monthly preset repeats on the start's weekday of the month", %{
    lv: lv,
    review: review
  } do
    lv |> edit(review) |> choose("monthly")

    uid = review.uid
    assert_receive {:written, ^uid, %{recurrence_rule: "FREQ=MONTHLY;BYDAY=2WE"}}
  end

  test "Custom… opens the repeat editor and writes nothing", %{lv: lv, review: review} do
    lv |> edit(review) |> choose("custom")

    assert has_element?(lv, "#calendar-panel-repeat-custom #recurrence-editor-form-panel-repeat")
    refute_receive {:written, _uid, _payload}, 200
  end

  test "a custom pattern is written by Save repeat", %{lv: lv, review: review} do
    lv |> edit(review) |> choose("custom")

    lv
    |> element("#recurrence-editor-form-panel-repeat")
    |> render_change(%{"freq" => "daily", "interval" => "2", "end_type" => "never"})

    refute_receive {:written, _uid, _payload}, 100
    lv |> element("#calendar-panel-repeat-custom button", "Save repeat") |> render_click()

    uid = review.uid
    assert_receive {:written, ^uid, %{recurrence_rule: "FREQ=DAILY;INTERVAL=2"}}
  end

  test "a pattern Outlook would refuse is refused before anything is written", %{
    conn: conn,
    user: user
  } do
    outlook =
      insert(:calendar_integration,
        user: user,
        name: "Outlook account",
        provider: "outlook",
        is_active: true,
        calendar_list: [%{"id" => "cal", "name" => "Calendar", "selected" => true}]
      )

    # Friday 30 October: a monthly "on day 30" has no February.
    retro = event(outlook, "cal", "Retro", ~U[2026-10-30 10:00:00Z], 60, provider: "outlook")
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-29")

    lv |> edit(retro) |> choose("custom")

    lv
    |> element("#recurrence-editor-form-panel-repeat")
    |> render_change(%{
      "freq" => "monthly",
      "interval" => "1",
      "on" => "day",
      "end_type" => "never"
    })

    lv |> element("#calendar-panel-repeat-custom button", "Save repeat") |> render_click()

    eventually(fn -> assert status(lv) =~ "Outlook can't skip the months" end)
    refute_receive {:written, _uid, _payload}, 200
  end

  describe "a member of a repeating series" do
    setup %{conn: conn, integration: integration} do
      standup =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series"
        )

      # Mounted after the series member exists, so the grid holds it.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      %{standup: standup, lv: lv}
    end

    test "shows that it repeats without naming a pattern it does not carry", %{
      lv: lv,
      standup: standup
    } do
      edit(lv, standup)

      assert has_element?(
               lv,
               "#calendar-panel-repeat-preset option[value='keep'][selected]",
               "Repeats"
             )
    end

    test "a new rule offers this and the following events, or all of them", %{
      lv: lv,
      standup: standup
    } do
      lv |> edit(standup) |> choose("daily")

      assert has_element?(lv, "#calendar-series-scope", "Standup")
      assert has_element?(lv, "#calendar-scope-following")
      assert has_element?(lv, "#calendar-scope-all")
      refute has_element?(lv, "#calendar-scope-this_only")
      refute_received {:written, _uid, _payload}
    end

    test "removing the rule is refused without asking", %{lv: lv, standup: standup} do
      lv |> edit(standup) |> choose("none")

      refute has_element?(lv, "#calendar-series-scope")

      assert status(lv) =~
               "A repeat rule can only be changed for all events, or this and following events"

      refute_receive {:written, _uid, _payload}, 200
    end
  end
end
