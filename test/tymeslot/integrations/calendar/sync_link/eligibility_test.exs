defmodule Tymeslot.Integrations.Calendar.SyncLink.EligibilityTest do
  @moduledoc """
  The single loop-prevention rule, pinned.

  The rule that matters most here is the first one: a cached event whose
  `{integration_id, uid}` is already in the mirror set is a leaf and must never
  spawn a mirror of its own. Everything else in this module — recurrence,
  transparency, cancellation — is a scoping rule that can be relaxed later; that
  one is what stops two linked calendars writing placeholders at each other
  forever.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility

  @integration_id 42

  defp event(attrs) do
    defaults = %{
      uid: "source-uid",
      calendar_integration_id: @integration_id,
      provider: :google,
      provider_calendar_id: "primary",
      provider_event_id: "pid-1",
      all_day: false,
      start_at: ~U[2026-07-03 10:00:00Z],
      end_at: ~U[2026-07-03 11:00:00Z],
      synced_at: ~U[2026-07-01 00:00:00Z]
    }

    CalendarEvent.new!(Map.merge(defaults, Map.new(attrs)))
  end

  describe "mirror_source?/2 — loop prevention" do
    test "an ordinary event on a source calendar is an eligible source" do
      assert Eligibility.mirror_source?(event([]), MapSet.new())
    end

    test "an event already recorded as a mirror is never a source again" do
      mirrors = MapSet.new([{@integration_id, "source-uid"}])

      refute Eligibility.mirror_source?(event([]), mirrors)
    end

    test "the mirror set is keyed on integration as well as UID" do
      mirrors = MapSet.new([{@integration_id + 1, "source-uid"}])

      assert Eligibility.mirror_source?(event([]), mirrors),
             "a mirror living on a different integration must not disqualify this event"
    end
  end

  describe "mirror_source?/2 — scoping rules" do
    test "a recurring source is skipped: a series collapses to one cache row" do
      refute Eligibility.mirror_source?(
               event(recurrence_rule: "FREQ=WEEKLY;COUNT=10"),
               MapSet.new()
             )
    end

    test "a transparent event is skipped: it does not consume the owner's time" do
      refute Eligibility.mirror_source?(event(transparency: :transparent), MapSet.new())
    end

    test "a cancelled event is skipped" do
      refute Eligibility.mirror_source?(event(status: :cancelled), MapSet.new())
    end

    test "a declined event is skipped" do
      refute Eligibility.mirror_source?(event(status: :declined), MapSet.new())
    end

    test "a tentative event still blocks time and is an eligible source" do
      assert Eligibility.mirror_source?(event(status: :tentative), MapSet.new())
    end
  end

  describe "worth_enqueueing?/2" do
    test "an ordinary event is worth a job" do
      assert Eligibility.worth_enqueueing?(event([]), MapSet.new())
    end

    test "a mirror is refused here as firmly as at the write" do
      refute Eligibility.worth_enqueueing?(
               event([]),
               MapSet.new([{@integration_id, "source-uid"}])
             )
    end

    test "a recurring event is refused: no placeholder can exist to withdraw" do
      refute Eligibility.worth_enqueueing?(event(recurrence_rule: "FREQ=DAILY"), MapSet.new())
    end

    test "an event that has stopped blocking time is still worth a job" do
      # It may already have a placeholder holding a slot the organiser has just
      # freed, and only the worker knows whether one exists.
      assert Eligibility.worth_enqueueing?(event(transparency: :transparent), MapSet.new())
      assert Eligibility.worth_enqueueing?(event(status: :cancelled), MapSet.new())
      assert Eligibility.worth_enqueueing?(event(status: :declined), MapSet.new())
    end
  end

  describe "mirror_source?/2 — cache rows" do
    test "accepts a ProviderCalendarEventSchema row, whose fields are strings" do
      row = %Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema{
        uid: "source-uid",
        calendar_integration_id: @integration_id,
        transparency: "opaque",
        status: "confirmed"
      }

      assert Eligibility.mirror_source?(row, MapSet.new())
      refute Eligibility.mirror_source?(row, MapSet.new([{@integration_id, "source-uid"}]))
      refute Eligibility.mirror_source?(%{row | status: "cancelled"}, MapSet.new())
      refute Eligibility.mirror_source?(%{row | transparency: "transparent"}, MapSet.new())
      refute Eligibility.mirror_source?(%{row | recurrence_rule: "FREQ=DAILY"}, MapSet.new())
    end
  end
end
