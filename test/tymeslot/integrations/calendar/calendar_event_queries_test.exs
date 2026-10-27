defmodule Tymeslot.Integrations.Calendar.CalendarEventQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.AvailabilityView
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries

  describe "in_range/3 with blocking rules" do
    setup do
      integration =
        insert(:calendar_integration,
          provider: "google",
          calendar_list: [
            %{id: "work", selected: true},
            %{id: "holidays", selected: true, blocks_availability: false}
          ]
        )

      for calendar_id <- ["work", "holidays"] do
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider_calendar_id: calendar_id,
          summary: calendar_id,
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z]
        )
      end

      %{integration: integration, rules: AvailabilityView.rules([integration])}
    end

    test "keeps only blocking calendars' rows, for either range shape", %{
      integration: integration,
      rules: rules
    } do
      for range <- [
            {~U[2026-06-01 00:00:00Z], ~U[2026-06-30 23:59:59Z]},
            {~D[2026-06-01], ~D[2026-06-30]}
          ] do
        assert [%CalendarEvent{summary: "work"}] =
                 CalendarEventQueries.in_range([integration.id], range, rules)
      end
    end
  end

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

    test "returns all-day event when its start_date equals the date of range_end midnight" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-06-15],
        end_date: ~D[2026-06-17],
        start_at: nil,
        end_at: nil
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~U[2026-06-10 00:00:00Z], ~U[2026-06-15 00:00:00Z]}
        )

      assert [%CalendarEvent{all_day: true, start_date: ~D[2026-06-15]}] = result
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

    test "returns all-day event when its start_date equals a single-day range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-06-15],
        end_date: ~D[2026-06-17],
        start_at: nil,
        end_at: nil
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~D[2026-06-15], ~D[2026-06-15]}
        )

      assert [%CalendarEvent{all_day: true, start_date: ~D[2026-06-15]}] = result
    end

    test "returns all-day event when its start_date equals the range_end" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-06-15],
        end_date: ~D[2026-06-17],
        start_at: nil,
        end_at: nil
      )

      result =
        CalendarEventQueries.in_range(
          [integration.id],
          {~D[2026-06-10], ~D[2026-06-15]}
        )

      assert [%CalendarEvent{all_day: true}] = result
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

      # The domain struct carries atoms where the schema stores strings.
      assert %CalendarEvent{} = event
      assert event.provider == :google
      assert event.status == :confirmed
      assert event.transparency == :opaque
    end
  end

  describe "in_range/2 and the role discriminator" do
    setup do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      %{integration: integration}
    end

    test "returns busy_only rows, which are the only Exchange rows that block", %{
      integration: integration
    } do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "busy-row",
        role: "busy_only",
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z]
      )

      assert [%CalendarEvent{uid: "busy-row"}] = in_june(integration)
    end

    test "excludes display_only rows, whose times cannot be trusted to block", %{
      integration: integration
    } do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "display-row",
        role: "display_only",
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z]
      )

      assert in_june(integration) == []
    end

    test "still returns the default `both` rows every other provider writes", %{
      integration: integration
    } do
      row =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "ordinary-row",
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z]
        )

      assert row.role == "both"
      assert [%CalendarEvent{uid: "ordinary-row"}] = in_june(integration)
    end

    test "applies the same filter to a Date range", %{integration: integration} do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "display-all-day",
        role: "display_only",
        all_day: true,
        start_date: ~D[2026-06-10],
        end_date: ~D[2026-06-11],
        start_at: nil,
        end_at: nil
      )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "busy-all-day",
        role: "busy_only",
        all_day: true,
        start_date: ~D[2026-06-10],
        end_date: ~D[2026-06-11],
        start_at: nil,
        end_at: nil
      )

      uids =
        [integration.id]
        |> CalendarEventQueries.in_range({~D[2026-06-01], ~D[2026-06-30]})
        |> Enum.map(& &1.uid)

      assert uids == ["busy-all-day"]
    end
  end

  describe "any_in_range?/4" do
    setup do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "busy-row",
        role: "busy_only",
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z]
      )

      %{integration: integration}
    end

    test "sees the role it is asked about", %{integration: integration} do
      assert CalendarEventQueries.any_in_range?(
               integration.id,
               "busy_only",
               ~U[2026-06-01 00:00:00Z],
               ~U[2026-06-30 23:59:59Z]
             )
    end

    test "does not let one role's rows answer for another's", %{integration: integration} do
      refute CalendarEventQueries.any_in_range?(
               integration.id,
               "display_only",
               ~U[2026-06-01 00:00:00Z],
               ~U[2026-06-30 23:59:59Z]
             )
    end

    test "is bounded by the window", %{integration: integration} do
      refute CalendarEventQueries.any_in_range?(
               integration.id,
               "busy_only",
               ~U[2026-07-01 00:00:00Z],
               ~U[2026-07-31 23:59:59Z]
             )
    end

    test "sees every role when asked about none", %{integration: integration} do
      assert CalendarEventQueries.any_in_range?(
               integration.id,
               nil,
               ~U[2026-06-01 00:00:00Z],
               ~U[2026-06-30 23:59:59Z]
             )

      refute CalendarEventQueries.any_in_range?(
               integration.id,
               nil,
               ~U[2026-07-01 00:00:00Z],
               ~U[2026-07-31 23:59:59Z]
             )
    end
  end

  defp in_june(integration) do
    CalendarEventQueries.in_range(
      [integration.id],
      {~U[2026-06-01 00:00:00Z], ~U[2026-06-30 23:59:59Z]}
    )
  end
end
