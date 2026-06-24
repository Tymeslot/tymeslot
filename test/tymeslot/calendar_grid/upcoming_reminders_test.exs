defmodule Tymeslot.CalendarGrid.UpcomingRemindersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid

  @now ~U[2026-06-24 12:00:00.000000Z]

  setup do
    integration = insert(:calendar_integration, is_active: true)
    {:ok, integration: integration}
  end

  defp event(integration, attrs) do
    insert(
      :provider_calendar_event,
      Keyword.merge([calendar_integration: integration, reminders: []], attrs)
    )
  end

  test "returns only upcoming timed events that carry reminders, with normalised offsets", %{
    integration: integration
  } do
    keep =
      event(integration,
        summary: "keep",
        all_day: false,
        start_at: DateTime.add(@now, 2, :hour),
        reminders: [%{"method" => "popup", "minutes_before" => 10}]
      )

    # Past event — excluded.
    event(integration,
      start_at: DateTime.add(@now, -1, :hour),
      reminders: [%{"method" => "popup", "minutes_before" => 10}]
    )

    # Upcoming but no reminders — excluded.
    event(integration, start_at: DateTime.add(@now, 3, :hour), reminders: [])

    # Beyond the 8-day window — excluded.
    event(integration,
      start_at: DateTime.add(@now, 9, :day),
      reminders: [%{"method" => "popup", "minutes_before" => 10}]
    )

    # All-day — excluded (no clock time to fire against).
    event(integration,
      all_day: true,
      start_at: nil,
      start_date: ~D[2026-06-25],
      end_date: ~D[2026-06-26],
      reminders: [%{"method" => "popup", "minutes_before" => 10}]
    )

    result = CalendarGrid.list_upcoming_events_with_reminders([integration.id], @now)

    assert [%{id: id, summary: "keep", reminders: [%{method: :popup, minutes_before: 10}]}] =
             result

    assert id == keep.id
  end

  test "returns [] when no integrations are given", %{integration: integration} do
    event(integration,
      start_at: DateTime.add(@now, 2, :hour),
      reminders: [%{"method" => "popup", "minutes_before" => 10}]
    )

    assert CalendarGrid.list_upcoming_events_with_reminders([], @now) == []
  end
end
