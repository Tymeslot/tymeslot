defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventQueriesPruningTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  describe "prune_ended_before/1" do
    test "deletes timed events that ended before cutoff" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z]
      )

      future =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: ~U[2026-07-01 10:00:00Z],
          end_at: ~U[2026-07-01 11:00:00Z]
        )

      assert 1 = ProviderCalendarEventQueries.prune_ended_before(cutoff)
      assert Repo.get(ProviderCalendarEventSchema, future.id)
    end

    test "deletes all-day events that ended before cutoff" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-04-01],
        end_date: ~D[2026-04-02],
        start_at: nil,
        end_at: nil
      )

      future =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          all_day: true,
          start_date: ~D[2026-07-01],
          end_date: ~D[2026-07-02],
          start_at: nil,
          end_at: nil
        )

      assert 1 = ProviderCalendarEventQueries.prune_ended_before(cutoff)
      assert Repo.get(ProviderCalendarEventSchema, future.id)
    end
  end

  describe "prune_inactive_integrations/0" do
    test "deletes events for inactive integrations" do
      user = insert(:user)
      active = insert(:calendar_integration, user: user, is_active: true)
      inactive = insert(:calendar_integration, user: user, is_active: false)

      kept = insert(:provider_calendar_event, calendar_integration: active)
      insert(:provider_calendar_event, calendar_integration: inactive)

      assert 1 = ProviderCalendarEventQueries.prune_inactive_integrations()
      assert Repo.get(ProviderCalendarEventSchema, kept.id)
    end
  end
end
