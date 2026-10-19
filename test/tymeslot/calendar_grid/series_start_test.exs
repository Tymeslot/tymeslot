defmodule Tymeslot.CalendarGrid.SeriesStartTest do
  @moduledoc """
  Where a series begins, which a whole-series repeat pattern is written
  against, for each way a provider keeps it.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.SeriesStart
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries

  test "a CalDAV occurrence starts where its master's DTSTART does" do
    integration = insert(:calendar_integration, provider: "caldav")

    ical =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "BEGIN:VEVENT",
          "UID:standup",
          "DTSTART;TZID=Europe/Berlin:20260930T090000",
          "DTEND;TZID=Europe/Berlin:20260930T100000",
          "RRULE:FREQ=WEEKLY",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      )

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "caldav",
        uid: "standup_20261014T090000",
        start_at: ~U[2026-10-14 07:00:00Z],
        recurrence_rule: "FREQ=WEEKLY",
        raw_ical: ical
      )

    assert CalendarGrid.series_start(event) == ~U[2026-09-30 07:00:00Z]
  end

  test "a Google or Outlook occurrence starts where its master read does" do
    integration = insert(:calendar_integration, provider: "google")

    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, "series1", %{
        rule: "FREQ=WEEKLY",
        master_start: ~U[2026-09-30 09:00:00Z],
        fetched_at: DateTime.utc_now()
      })

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "google",
        recurring_event_id: "series1",
        start_at: ~U[2026-10-14 09:00:00Z],
        recurrence_rule: "FREQ=WEEKLY"
      )

    assert CalendarGrid.series_start(event) == ~U[2026-09-30 09:00:00Z]

    unread = %{event | recurring_event_id: "series2"}
    assert CalendarGrid.series_start(unread) == nil
  end

  test "an all-day series starts on a day, and an event of no series on its own start" do
    integration = insert(:calendar_integration, provider: "google")

    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, "series1", %{
        rule: "FREQ=YEARLY",
        master_start: ~U[2026-09-30 00:00:00Z],
        fetched_at: DateTime.utc_now()
      })

    all_day =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "google",
        recurring_event_id: "series1",
        all_day: true,
        start_date: ~D[2027-09-30],
        recurrence_rule: "FREQ=YEARLY"
      )

    one_off =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-10-14 09:00:00Z]
      )

    assert CalendarGrid.series_start(all_day) == ~D[2026-09-30]
    assert DateTime.compare(CalendarGrid.series_start(one_off), ~U[2026-10-14 09:00:00Z]) == :eq
  end

  # By 30 April a series on the 31st has been on 31 January, 28 February and
  # 31 March in Outlook, which puts it on a shorter month's last day; RFC
  # 5545 skips February.
  test "Outlook counts an absolute monthly series on the 31st as Graph does" do
    count = &SeriesStart.count_before(&1, "FREQ=MONTHLY", ~D[2026-01-31], ~D[2026-04-30])

    assert count.("outlook") == 3
    assert count.("google") == 2
  end

  test "only Outlook refuses a rule, for a day some months lack" do
    assert CalendarGrid.repeat_refusal("outlook", "FREQ=MONTHLY", ~D[2026-12-31], "Etc/UTC") ==
             :day_missing_in_some_months

    assert CalendarGrid.repeat_refusal("outlook", "FREQ=MONTHLY", ~D[2026-12-28], "Etc/UTC") ==
             nil

    assert CalendarGrid.repeat_refusal("google", "FREQ=MONTHLY", ~D[2026-12-31], "Etc/UTC") ==
             nil
  end
end
