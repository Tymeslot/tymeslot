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
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries

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

  test "a calendar that takes no repeat rules refuses a pushed repeat change", %{
    conn: conn,
    user: user
  } do
    exchange =
      insert(:calendar_integration,
        user: user,
        name: "Exchange account",
        provider: "exchange",
        is_active: true,
        calendar_list: [%{"id" => "ex", "name" => "Calendar", "selected" => true}]
      )

    sync = event(exchange, "ex", "Sync", ~U[2026-10-14 11:00:00Z], 60, provider: "exchange")
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")

    lv |> edit(sync) |> choose("daily")

    assert status(lv) =~ "This calendar doesn't take repeat rules from Tymeslot."
    refute_receive {:written, _uid, _payload}, 200
  end

  test "undoing a rule given to a one-off writes nothing", %{lv: lv, review: review} do
    lv |> edit(review) |> choose("weekly")
    uid = review.uid
    assert_receive {:written, ^uid, %{recurrence_rule: "FREQ=WEEKLY"}}

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    assert has_element?(lv, "#calendar-toast", "Nothing to undo.")
    refute_receive {:written, ^uid, %{recurrence_rule: nil}}, 200
  end

  describe "a member of a repeating series" do
    setup %{conn: conn, integration: integration} do
      standup =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          uid: "standup-series_20261014T083000Z",
          provider_event_id: "standup-series_20261014T083000Z",
          recurring_event_id: "standup-series"
        )

      # The series' own start, which a rule for all of it is written against.
      {:ok, _row} =
        SeriesRuleQueries.put(integration.id, "standup-series", %{
          rule: "FREQ=DAILY",
          master_start: ~U[2026-10-01 08:30:00Z],
          fetched_at: DateTime.utc_now()
        })

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

    test "closing the panel drops the series question, and opening another event does too", %{
      lv: lv,
      standup: standup,
      review: review
    } do
      lv |> edit(standup) |> choose("daily")
      assert has_element?(lv, "#calendar-series-scope")

      lv |> element("#calendar-canvas") |> render_hook("panel:close", %{})
      refute has_element?(lv, "#calendar-series-scope")

      lv |> edit(standup) |> choose("daily")
      assert has_element?(lv, "#calendar-series-scope")

      edit(lv, review)
      refute has_element?(lv, "#calendar-series-scope")
      refute_receive {:written, _uid, _payload}, 200
    end

    test "removing the rule is refused without asking", %{lv: lv, standup: standup} do
      lv |> edit(standup) |> choose("none")

      refute has_element?(lv, "#calendar-series-scope")

      assert status(lv) =~
               "A repeat rule can only be changed for all events, or this and following events"

      refute_receive {:written, _uid, _payload}, 200
    end

    test "removing the rule puts the select back to what the event has", %{
      lv: lv,
      standup: standup
    } do
      lv |> edit(standup) |> choose("none")

      assert has_element?(lv, "#calendar-panel-repeat-preset option[value='keep'][selected]")
      refute has_element?(lv, "#calendar-panel-repeat-preset option[value='none'][selected]")
      # A new id makes the browser draw the select again with that value.
      assert has_element?(lv, "#calendar-panel-repeat-field-1")
      refute has_element?(lv, "#calendar-panel-repeat-field-0")
    end

    test "this and following is written from where the series put the event", %{
      lv: lv,
      standup: standup
    } do
      lv |> edit(standup) |> choose("daily")
      lv |> element("#calendar-scope-following") |> render_click()

      uid = standup.uid
      assert_receive {:written, ^uid, %{recurrence_rule: "FREQ=DAILY"} = payload}

      assert %{
               scope: :following,
               slot: ~U[2026-10-14 08:30:00Z],
               master_id: "standup-series",
               until_timezone: "Europe/London",
               changes: %{recurrence_rule: "FREQ=DAILY"}
             } = payload.occurrence
    end

    test "a rule change asks again when the panel holds this event only", %{
      lv: lv,
      standup: standup
    } do
      lv
      |> edit(standup)
      |> element("#calendar-panel-title")
      |> render_blur(%{"value" => "Stand-up"})

      lv |> element("#calendar-scope-this_only") |> render_click()
      refute has_element?(lv, "#calendar-series-scope")

      choose(lv, "daily")

      assert has_element?(lv, "#calendar-series-scope")
      refute has_element?(lv, "#calendar-scope-this_only")
    end

    test "the answer to a rule change is not kept for later field edits", %{
      lv: lv,
      standup: standup
    } do
      lv |> edit(standup) |> choose("daily")
      lv |> element("#calendar-scope-all") |> render_click()
      uid = standup.uid
      assert_receive {:written, ^uid, %{recurrence_rule: "FREQ=DAILY"}}
      eventually(fn -> assert status(lv) =~ "Saved" end)

      lv
      |> element("#calendar-panel-location")
      |> render_keydown(%{"key" => "Enter", "value" => "Room 4"})

      assert has_element?(lv, "#calendar-series-scope")
      assert has_element?(lv, "#calendar-scope-this_only")
      refute_receive {:written, ^uid, %{location: "Room 4"}}, 200
    end

    test "the answer to a rule change does not replace this event only", %{
      lv: lv,
      standup: standup
    } do
      lv
      |> edit(standup)
      |> element("#calendar-panel-title")
      |> render_blur(%{"value" => "Stand-up"})

      lv |> element("#calendar-scope-this_only") |> render_click()
      uid = standup.uid
      assert_receive {:written, ^uid, %{summary: "Stand-up"}}

      choose(lv, "daily")
      lv |> element("#calendar-scope-all") |> render_click()
      assert_receive {:written, ^uid, %{recurrence_rule: "FREQ=DAILY"}}
      eventually(fn -> assert status(lv) =~ "Saved" end)

      lv
      |> element("#calendar-panel-location")
      |> render_keydown(%{"key" => "Enter", "value" => "Room 4"})

      refute has_element?(lv, "#calendar-series-scope")
      assert_receive {:written, ^uid, %{location: "Room 4"} = payload}
      refute Map.has_key?(payload, :occurrence)
    end
  end
end
