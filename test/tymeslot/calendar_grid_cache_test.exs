defmodule Tymeslot.CalendarGridCacheTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  alias Tymeslot.CalendarGrid

  describe "cache_created_event/1" do
    test "accepts second-precision DateTimes from the dashboard create flow" do
      # Regression: the in-dashboard create handler builds start_at/end_at via
      # DateTime.new!/Time.new!, which yields second precision. The cached events
      # schema uses :utc_datetime_usec, so the cache path must upcast or tolerate
      # the lower precision instead of crashing in insert_all.
      integration = insert(:calendar_integration)

      start_at = DateTime.new!(~D[2026-04-14], ~T[15:45:00], "Etc/UTC")
      end_at = DateTime.new!(~D[2026-04-14], ~T[16:15:00], "Etc/UTC")

      assert :ok =
               CalendarGrid.cache_created_event(%{
                 uid: "regression-second-precision",
                 calendar_integration_id: integration.id,
                 provider: "nextcloud",
                 provider_calendar_id: "primary",
                 summary: "Test",
                 start_at: start_at,
                 end_at: end_at,
                 all_day: false
               })

      assert {:ok, cached} =
               CalendarGrid.get_cached_event(integration.id, "regression-second-precision")

      assert cached.summary == "Test"
    end
  end

  describe "update_cached_event/1" do
    test "accepts second-precision synced_at from the dashboard update flow" do
      # Regression: EditWorkflow.Updates.update_event_async / update_attendees_async /
      # update_field_async previously built cache rows with
      # DateTime.utc_now(:second). synced_at is :utc_datetime_usec, so the cache
      # path must upcast lower precision instead of crashing the async task in
      # Repo.insert_all.
      integration = insert(:calendar_integration)

      insert(:provider_calendar_event,
        uid: "regression-update-second-precision",
        calendar_integration: integration,
        summary: "Before"
      )

      start_at = DateTime.new!(~D[2026-04-14], ~T[15:45:00], "Etc/UTC")
      end_at = DateTime.new!(~D[2026-04-14], ~T[16:15:00], "Etc/UTC")

      assert :ok =
               CalendarGrid.update_cached_event(%{
                 uid: "regression-update-second-precision",
                 calendar_integration_id: integration.id,
                 provider: "nextcloud",
                 provider_calendar_id: "primary",
                 summary: "After",
                 start_at: start_at,
                 end_at: end_at,
                 all_day: false,
                 synced_at: DateTime.utc_now(:second)
               })

      assert {:ok, cached} =
               CalendarGrid.get_cached_event(integration.id, "regression-update-second-precision")

      assert cached.summary == "After"
    end
  end
end
