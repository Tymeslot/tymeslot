defmodule Tymeslot.CalendarGridCacheTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Mox

  alias Tymeslot.CalendarGrid

  setup :verify_on_exit!

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

  describe "update_event/4" do
    test "accepts second-precision DateTimes from the dashboard edit flow" do
      # Regression: the grid builds a dragged or edited event's times at second
      # precision, while the cached events schema stores :utc_datetime_usec, so
      # recording the edit on the cached row must upcast rather than crash the
      # async task.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      event =
        insert(:provider_calendar_event,
          uid: "regression-update-second-precision",
          calendar_integration: integration,
          summary: "Before"
        )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)

      start_at = DateTime.new!(~D[2026-04-14], ~T[15:45:00], "Etc/UTC")
      end_at = DateTime.new!(~D[2026-04-14], ~T[16:15:00], "Etc/UTC")

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{
                 summary: "After",
                 start_at: start_at,
                 end_at: end_at
               })

      assert {:ok, cached} =
               CalendarGrid.get_cached_event(integration.id, "regression-update-second-precision")

      assert {cached.summary, cached.start_at} ==
               {"After", ~U[2026-04-14 15:45:00.000000Z]}
    end
  end
end
