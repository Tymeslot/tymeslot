defmodule Tymeslot.Integrations.Calendar.CalendarEventQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries

  describe "in_range/2 with DateTime range" do
    test "returns timed events overlapping the range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z]
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~U[2026-06-01 00:00:00Z], ~U[2026-06-30 23:59:59Z]}
        )

      assert [%CalendarEvent{} = event] = result
      assert event.start_at == ~U[2026-06-15 10:00:00.000000Z]
    end

    test "returns all-day events overlapping a DateTime range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-06-10],
        end_date: ~D[2026-06-11],
        start_at: nil,
        end_at: nil
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~U[2026-06-01 00:00:00Z], ~U[2026-06-30 23:59:59Z]}
        )

      assert [%CalendarEvent{all_day: true}] = result
    end

    test "excludes out-of-range events" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # Before range
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z]
      )

      # After range
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-08-01 10:00:00Z],
        end_at: ~U[2026-08-01 11:00:00Z]
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~U[2026-06-01 00:00:00Z], ~U[2026-06-30 23:59:59Z]}
        )

      assert result == []
    end

    test "returns empty list for empty integration_ids" do
      assert [] =
               CalendarEventQueries.in_range(
                 [],
                 {~U[2026-06-01 00:00:00Z], ~U[2026-06-30 23:59:59Z]}
               )
    end
  end

  describe "in_range/2 with Date range" do
    test "returns timed events overlapping the date range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z]
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~D[2026-06-01], ~D[2026-06-30]}
        )

      assert [%CalendarEvent{}] = result
    end

    test "returns all-day events overlapping the date range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-06-10],
        end_date: ~D[2026-06-11],
        start_at: nil,
        end_at: nil
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~D[2026-06-01], ~D[2026-06-30]}
        )

      assert [%CalendarEvent{all_day: true}] = result
    end

    test "excludes all-day events outside the date range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-08-01],
        end_date: ~D[2026-08-02],
        start_at: nil,
        end_at: nil
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~D[2026-06-01], ~D[2026-06-30]}
        )

      assert result == []
    end
  end

  describe "in_range/2 returns CalendarEvent structs" do
    test "results are CalendarEvent structs, not schema structs" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z]
      )

      [event] =
        CalendarEventQueries.in_range(
          [integration.id],
          {~U[2026-06-01 00:00:00Z], ~U[2026-06-30 23:59:59Z]}
        )

      assert %CalendarEvent{} = event
      refute is_struct(event, Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema)
      assert is_atom(event.provider)
      assert is_atom(event.status)
      assert is_atom(event.transparency)
    end
  end
end
