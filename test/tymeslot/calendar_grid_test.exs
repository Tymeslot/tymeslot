defmodule Tymeslot.CalendarGridTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  alias Tymeslot.CalendarGrid

  describe "get_integration_color_indices/1" do
    test "returns empty map for empty list" do
      assert CalendarGrid.get_integration_color_indices([]) == %{}
    end

    test "assigns index 1 to a single integration" do
      result = CalendarGrid.get_integration_color_indices([%{id: 42}])
      assert result == %{42 => 1}
    end

    test "assigns indices by sorted id, not input order" do
      integrations = [%{id: 30}, %{id: 10}, %{id: 20}]
      result = CalendarGrid.get_integration_color_indices(integrations)

      # id 10 is first when sorted → index 1
      # id 20 is second → index 2
      # id 30 is third → index 3
      assert result == %{10 => 1, 20 => 2, 30 => 3}
    end

    test "rotates indices after palette size (8)" do
      integrations = Enum.map(1..10, &%{id: &1})
      result = CalendarGrid.get_integration_color_indices(integrations)

      # First 8 get indices 1..8, then wrap
      assert result[1] == 1
      assert result[8] == 8
      assert result[9] == 1
      assert result[10] == 2
    end
  end

  describe "list_events_for_range/3" do
    setup do
      integration = insert(:calendar_integration)
      %{integration: integration}
    end

    test "returns events within the time range", %{integration: integration} do
      event =
        insert(:calendar_event_cache,
          calendar_integration: integration,
          start_at: ~U[2026-03-15 10:00:00Z],
          end_at: ~U[2026-03-15 11:00:00Z]
        )

      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert [found] = result
      assert found.id == event.id
    end

    test "excludes events outside the time range", %{integration: integration} do
      insert(:calendar_event_cache,
        calendar_integration: integration,
        start_at: ~U[2026-03-10 10:00:00Z],
        end_at: ~U[2026-03-10 11:00:00Z]
      )

      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end

    test "excludes events from other integrations", %{integration: integration} do
      other = insert(:calendar_integration)

      insert(:calendar_event_cache,
        calendar_integration: other,
        start_at: ~U[2026-03-15 10:00:00Z],
        end_at: ~U[2026-03-15 11:00:00Z]
      )

      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end

    test "excludes events ending exactly at range start (strict boundary)", %{integration: integration} do
      insert(:calendar_event_cache,
        calendar_integration: integration,
        start_at: ~U[2026-03-14 23:00:00Z],
        end_at: ~U[2026-03-15 00:00:00Z]
      )

      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end

    test "returns empty list when no events match", %{integration: integration} do
      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end

    test "returns empty list for empty integration IDs" do
      result =
        CalendarGrid.list_events_for_range(
          [],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end
  end
end
