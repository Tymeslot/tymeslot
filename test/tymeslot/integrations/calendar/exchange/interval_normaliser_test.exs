defmodule Tymeslot.Integrations.Calendar.Exchange.IntervalNormaliserTest do
  @moduledoc """
  Covers the synthesis of cacheable events from identity-less busy intervals:
  the uid's namespace and stability, and the two row-level fields without which
  a `busy_only` row would occupy the cache and block nothing.
  """

  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Exchange.IntervalNormaliser

  @context %{calendar_integration_id: 42, synced_at: ~U[2026-08-19 12:00:00Z]}

  defp interval(start_at, end_at, busy_type \\ :busy) do
    %{start_at: start_at, end_at: end_at, busy_type: busy_type}
  end

  defp normalise(intervals, context \\ @context) do
    {:ok, events} = IntervalNormaliser.normalise_intervals(intervals, context)
    events
  end

  describe "the synthesised event" do
    test "blocks, because it is opaque and confirmed" do
      [event] = normalise([interval(~U[2026-09-01 09:00:00Z], ~U[2026-09-01 10:00:00Z])])

      assert event.transparency == :opaque
      assert event.status == :confirmed

      # The two fields above are the whole reason the row blocks: `role` is a
      # query-level filter and `blocking?/1` never reads it.
      assert CalendarEvent.blocking?(event)
    end

    test "carries the interval's bounds and nothing invented about the meeting" do
      [event] = normalise([interval(~U[2026-09-01 09:00:00Z], ~U[2026-09-01 10:00:00Z])])

      assert event.start_at == ~U[2026-09-01 09:00:00Z]
      assert event.end_at == ~U[2026-09-01 10:00:00Z]
      assert event.all_day == false
      assert event.summary == nil
      assert event.location == nil
      assert event.provider_event_id == nil
      assert event.provider == :exchange
    end

    test "records the busy type it was blocked for" do
      [event] =
        normalise([interval(~U[2026-09-01 09:00:00Z], ~U[2026-09-01 10:00:00Z], :out_of_office)])

      assert event.provider_metadata == %{"busy_type" => "out_of_office"}
    end
  end

  describe "the synthesised uid" do
    test "is namespaced away from every uid that shares the integration" do
      [event] = normalise([interval(~U[2026-09-01 09:00:00Z], ~U[2026-09-01 10:00:00Z])])

      assert String.starts_with?(event.uid, IntervalNormaliser.uid_prefix())
      assert IntervalNormaliser.uid_prefix() == "tymeslot:exchange-busy:"

      # A colon is what a UUID, a hex EWS UID and a base64 item id all cannot
      # contain, so it is the character carrying the guarantee.
      assert String.contains?(IntervalNormaliser.uid_prefix(), ":")
    end

    test "is identical for the same interval read twice" do
      intervals = [interval(~U[2026-09-01 09:00:00Z], ~U[2026-09-01 10:00:00Z])]

      [first] = normalise(intervals)
      [second] = normalise(intervals, %{@context | synced_at: ~U[2026-08-20 12:00:00Z]})

      assert first.uid == second.uid
    end

    test "does not depend on the interval's position in the response" do
      early = interval(~U[2026-09-01 09:00:00Z], ~U[2026-09-01 10:00:00Z])
      late = interval(~U[2026-09-02 09:00:00Z], ~U[2026-09-02 10:00:00Z])

      assert [_early_uid, late_uid] = Enum.map(normalise([early, late]), & &1.uid)
      assert [^late_uid] = Enum.map(normalise([late]), & &1.uid)
    end

    test "distinguishes two integrations reading the same wall-clock interval" do
      intervals = [interval(~U[2026-09-01 09:00:00Z], ~U[2026-09-01 10:00:00Z])]

      [mine] = normalise(intervals)
      [theirs] = normalise(intervals, %{@context | calendar_integration_id: 43})

      refute mine.uid == theirs.uid
    end

    test "distinguishes two busy types sharing one pair of bounds" do
      bounds = {~U[2026-09-01 09:00:00Z], ~U[2026-09-01 10:00:00Z]}
      {start_at, end_at} = bounds

      [busy] = normalise([interval(start_at, end_at, :busy)])
      [tentative] = normalise([interval(start_at, end_at, :tentative)])

      refute busy.uid == tentative.uid
    end
  end
end
