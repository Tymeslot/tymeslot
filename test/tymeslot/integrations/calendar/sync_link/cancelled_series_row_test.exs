defmodule Tymeslot.Integrations.Calendar.SyncLink.CancelledSeriesRowTest do
  @moduledoc """
  The correction surviving the trip from detection to the provider.

  ## Why this level, when the detection tests already pass

  Detection and correction are two Oban jobs with the cache between them, and
  every test written for the first stopped at the enqueue. That is where the
  live failure hid: `SyncGoogleCalendarWorker` produced a perfect `moved` list
  for four cancelled occurrences — verified against the real delta payload — and
  the placeholder still gained no `EXDATE`, because the *second* job refused the
  write before it ever read that list.

  `SyncLinkWriteBackWorker.upsert/5` re-reads the source from the cache and asks
  `Eligibility.mirror_source?/4`. A Google series is one cache row keyed on the
  shared `iCalUID`, and `upsert_batch/1` keeps the **last** entry — so once the
  final occurrence of a series is the cancelled one, the row that stands for the
  whole series carries `status: "cancelled"`, `off_the_calendar?/1` answers
  true, and the series is judged to be off the calendar entirely.

  The consequence is the opposite of the intent. The occurrence the organiser
  cancelled goes on blocking its slot, because the write that would have
  excepted it is the write being refused.

  ## The shapes here are the live ones

  The five events are the delta the API returned four seconds after a
  cancellation, captured from the organiser's own calendar: four cancelled
  instances and the one moved occurrence, all sharing the master's `iCalUID`,
  each carrying `originalStartTime` equal to its `start`.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  @master_id "56km0ibouqobmlmh3g5ptdmp28"
  @series_uid "56km0ibouqobmlmh3g5ptdmp28@google.com"

  defp occurrence(stamp, status, start_iso, original_iso) do
    %{
      "id" => "#{@master_id}_#{stamp}",
      "iCalUID" => @series_uid,
      "recurringEventId" => @master_id,
      "status" => status,
      "summary" => "TYMESLOT TEST weekly",
      "start" => %{"dateTime" => start_iso, "timeZone" => "UTC"},
      "end" => %{"dateTime" => start_iso, "timeZone" => "UTC"},
      "originalStartTime" => %{"dateTime" => original_iso, "timeZone" => "UTC"}
    }
  end

  # The delta exactly as the live API returned it: the last occurrence of the
  # series is cancelled, which is what makes the surviving cache row cancelled.
  defp live_delta do
    [
      occurrence("20260821T140000Z", "cancelled", "2026-08-21T14:00:00Z", "2026-08-21T14:00:00Z"),
      occurrence("20260828T140000Z", "cancelled", "2026-08-28T14:00:00Z", "2026-08-28T14:00:00Z"),
      occurrence("20260904T140000Z", "cancelled", "2026-09-04T14:00:00Z", "2026-09-04T14:00:00Z"),
      occurrence("20260911T140000Z", "confirmed", "2026-09-11T16:00:00Z", "2026-09-11T14:00:00Z"),
      occurrence("20260918T140000Z", "cancelled", "2026-09-18T14:00:00Z", "2026-09-18T14:00:00Z")
    ]
  end

  setup do
    user = insert(:user)

    source =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        google_sync_token: "valid-token"
      )

    target = insert(:calendar_integration, user: user, provider: "google")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    %{user: user, source: source, target: target, link: link}
  end

  test "a series whose last occurrence is cancelled still has its cancellations excepted",
       %{source: source} do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: live_delta(), next_sync_token: "new-token"}}
    end)

    assert :ok =
             perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => source.id})

    # Detection did its half — this is what passed while production failed.
    assert [job] = all_enqueued(worker: SyncLinkWriteBackWorker)
    assert job.args["source_uid"] == @series_uid
    # Four cancellations and the move, all five carried on the one job.
    assert length(job.args["moved"]) == 5

    # The master, so the placeholder has a rule to except against.
    expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, event_id ->
      assert event_id == @master_id
      {:ok, google_series_master(master_id: @master_id, rule: "RRULE:FREQ=WEEKLY;COUNT=5")}
    end)

    test_pid = self()

    expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:payload, event_data})
      {:ok, %{uid: "m30q27oojg9cboc9ja0cq2mlt6jtt119"}}
    end)

    # The second job — the one the live failure was hiding in.
    assert :ok = perform_job(SyncLinkWriteBackWorker, job.args)

    assert_received {:payload, payload}

    assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;COUNT=5"

    lines = payload.recurrence_exception_lines

    # Every cancelled occurrence freed, and the move still corrected.
    assert "EXDATE;TZID=Etc/UTC:20260821T140000" in lines
    assert "EXDATE;TZID=Etc/UTC:20260828T140000" in lines
    assert "EXDATE;TZID=Etc/UTC:20260904T140000" in lines
    assert "EXDATE;TZID=Etc/UTC:20260918T140000" in lines
  end
end
