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

  describe "mirror_source?/3 — scoping rules" do
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

  describe "mirror_source?/3 — recurrence turns on the target" do
    # The write gate is the only place the target's provider is known, and a
    # recurring source is the one case whose answer depends on it: Google
    # expands a series it is handed, so one placeholder carries the whole
    # thing, while a target that cannot would receive a single block at
    # whichever occurrence the cache happened to keep.
    test "a recurring source is eligible for a target that expands a series" do
      assert Eligibility.mirror_source?(
               event(recurrence_rule: "FREQ=WEEKLY;COUNT=10"),
               MapSet.new(),
               "google"
             )
    end

    test "the same recurring source is skipped for an Outlook target" do
      refute Eligibility.mirror_source?(
               event(recurrence_rule: "FREQ=WEEKLY;COUNT=10"),
               MapSet.new(),
               "outlook"
             )
    end

    test "and for a CalDAV target" do
      for provider <- ~w(caldav nextcloud radicale apple) do
        refute Eligibility.mirror_source?(
                 event(recurrence_rule: "FREQ=WEEKLY;COUNT=10"),
                 MapSet.new(),
                 provider
               ),
               "#{provider} must not be handed a recurring source"
      end
    end

    # Omitting the target is how every non-recurrence caller asks the question,
    # and the answer for a recurring source must be the conservative one: a
    # caller that does not know where the placeholder is going cannot have
    # established that the destination expands series.
    test "a recurring source is skipped when no target provider is named" do
      refute Eligibility.mirror_source?(
               event(recurrence_rule: "FREQ=WEEKLY;COUNT=10"),
               MapSet.new()
             )
    end

    # The target's capability never rescues an event refused for another
    # reason. A recurring mirror is still a leaf; a recurring cancelled event
    # still takes no time.
    test "a recurrence-capable target does not override the other refusals" do
      recurring = [recurrence_rule: "FREQ=WEEKLY"]

      refute Eligibility.mirror_source?(
               event(recurring),
               MapSet.new([{@integration_id, "source-uid"}]),
               "google"
             )

      refute Eligibility.mirror_source?(
               event(recurring ++ [status: :cancelled]),
               MapSet.new(),
               "google"
             )

      refute Eligibility.mirror_source?(
               event(recurring ++ [transparency: :transparent]),
               MapSet.new(),
               "google"
             )
    end

    test "a non-recurring source is unaffected by the target's provider" do
      for provider <- ["google", "outlook", "nextcloud", nil] do
        assert Eligibility.mirror_source?(event([]), MapSet.new(), provider)
      end
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

    # The narrower gate no longer refuses recurrence, and it cannot: it is
    # asked once for a batch of events shared across every link out of the
    # source calendar, so the per-link target it would have to consult is not
    # in hand. A recurring event is now worth a job for the same reason a
    # cancelled one is — the answer differs per link, and only the worker holds
    # the link.
    test "a recurring event is worth a job: whether it can be mirrored is per link" do
      assert Eligibility.worth_enqueueing?(event(recurrence_rule: "FREQ=DAILY"), MapSet.new())
    end

    test "an event that has stopped blocking time is still worth a job" do
      # It may already have a placeholder holding a slot the organiser has just
      # freed, and only the worker knows whether one exists.
      assert Eligibility.worth_enqueueing?(event(transparency: :transparent), MapSet.new())
      assert Eligibility.worth_enqueueing?(event(status: :cancelled), MapSet.new())
      assert Eligibility.worth_enqueueing?(event(status: :declined), MapSet.new())
    end
  end

  describe "mirror_source?/3 — cache rows" do
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

      recurring = %{row | recurrence_rule: "FREQ=DAILY"}
      refute Eligibility.mirror_source?(recurring, MapSet.new(), "outlook")
      assert Eligibility.mirror_source?(recurring, MapSet.new(), "google")
    end
  end
end
