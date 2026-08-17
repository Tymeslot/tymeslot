defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineRecurrenceRecreateTest do
  @moduledoc """
  A recurring placeholder the organiser deleted, written again.

  `recreate_missing/5` is a third create site, distinct from the ordinary create
  and from the 409 adoption, and the one place the resolved series options could
  be dropped on the way in. If they are, the replacement is a single block at
  the *cached row's* time — which under `singleEvents=true` is the last
  occurrence, months from where the series starts — and the row is then
  re-baselined to `active`, so the sweep sees a fresh mapping and never corrects
  it.

  Asserting on the payload rather than the row is the only thing that tells a
  recreated series from a recreated one-off block.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    context = linked_pair()
    {:ok, link} = CalendarSyncLinkQueries.get(context.link.id)
    %{context | link: link}
  end

  # The series as the cache holds it: one row carrying the LAST occurrence's
  # times, which is what a naive recreate would mirror.
  defp weekly_instance(source, attrs \\ %{}) do
    google_series_instance(source, attrs)
  end

  # The master's own start is March, the series' first occurrence.
  @master_start "2026-03-03T09:00:00Z"
  @master_end "2026-03-03T09:30:00Z"

  defp expect_master(recurrence, times \\ 1) do
    expect(GoogleCalendarAPIMock, :get_event, times, fn _integration, _calendar_id, event_id ->
      assert event_id == "master_abc123"

      {:ok,
       %{
         "id" => "master_abc123",
         "recurrence" => recurrence,
         "start" => %{"dateTime" => @master_start},
         "end" => %{"dateTime" => @master_end}
       }}
    end)
  end

  describe "a placeholder the organiser deleted is recreated as a series" do
    # The organiser deletes one "Busy" block from the target. The mapping row
    # survives, so the next pass updates — against an event the provider no
    # longer has — and `recreate_missing/5` writes it again.
    #
    # That path is a third create site, and the one place the resolved series
    # options could be dropped on the way in. If they are, the replacement is a
    # single block at the *cached row's* time, which for a series under
    # `singleEvents=true` is the last occurrence — a weekly standup that began
    # in March comes back as one block in December, months from where it
    # belongs, blocking a slot nothing occupies and freeing every slot that is.
    #
    # It then re-baselines the row to `active`, so the sweep sees a fresh
    # mapping and never corrects it. Asserting on the payload rather than the
    # row is the only thing that tells the two apart.
    test "the recreated placeholder carries the master's rule, not the cached instance's time",
         %{
           user: user,
           source: source,
           link: link
         } do
      mirror_for_link(link,
        source_uid: "weekly-series@google.com",
        target_uid: Engine.target_uid_for(link.id, "weekly-series@google.com"),
        state: "active"
      )

      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261215T090000Z"])

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:error, :not_found}
      end)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "recreated-id"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert_received {:payload, payload}

      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261215T090000Z"

      # March, from the master — not December, from the cached last occurrence.
      assert payload.start_time == ~U[2026-03-03 09:00:00Z]
    end
  end
end
