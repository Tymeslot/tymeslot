defmodule Tymeslot.Integrations.Calendar.SyncLink.CancelledOccurrenceTest do
  @moduledoc """
  Cancelling one occurrence of a mirrored series freeing that occurrence's slot
  on the target.

  ## Why this is not already covered by the master's EXDATEs

  `RecurringSeries` forwards the master's `EXDATE` lines onto the placeholder,
  and its moduledoc says that is what "stops a cancelled occurrence from going
  on blocking its slot". Measured against the live API on the organiser's own
  calendar, that is not what Google does. A series with one occurrence
  genuinely cancelled answered:

      "recurrence" => ["RRULE:FREQ=WEEKLY;COUNT=5"]

  No `EXDATE`, ever — Google records the cancellation on the *instance*, as a
  separate exception event with `status: "cancelled"`, and leaves the master's
  rule untouched. So the forwarding path is real and correct for a master that
  has EXDATEs, and simply never fires for a Google cancellation.

  ## The shape this is built from, measured rather than invented

  A direct `GET` of the cancelled instance on the live calendar returned:

      %{"id" => "56km0ibouqobmlmh3g5ptdmp28_20260828T140000Z",
        "iCalUID" => "56km0ibouqobmlmh3g5ptdmp28@google.com",
        "recurringEventId" => "56km0ibouqobmlmh3g5ptdmp28",
        "status" => "cancelled",
        "originalStartTime" => %{"dateTime" => "2026-08-28T11:00:00-03:00", ...},
        "start" => %{"dateTime" => "2026-08-28T11:00:00-03:00", ...}}

  Two facts in that body decide the design, and both were assumed otherwise
  before it was read:

  - a cancelled occurrence **does** carry `originalStartTime`, so the marker is
    not a move-only marker and the instant to except is directly readable;
  - `start` equals `originalStartTime`, so `moved?/1` answers false for it. The
    existing detection is not merely silent here — it is *correctly* silent,
    which is why the cancellation needed its own question rather than a loosened
    one.

  Both are reachable only on the delta path. A `syncToken` listing implies
  `showDeleted=true`, so a cancelled instance is returned there; the bootstrap
  and `list_events/4` paths send `singleEvents=true` with no `showDeleted` and
  simply omit it — measured as 0 cancelled items in a 634-event bootstrap of the
  same calendar.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Integrations.Calendar.SyncLink.MovedOccurrence
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    context = linked_pair()
    {:ok, link} = CalendarSyncLinkQueries.get(context.link.id)
    %{context | link: link}
  end

  @master_id "56km0ibouqobmlmh3g5ptdmp28"
  @series_uid "56km0ibouqobmlmh3g5ptdmp28@google.com"

  # One expanded instance of the live series, as `Google.EventNormaliser`
  # produces it. `uid` is `raw["iCalUID"]`, which every instance of the series
  # shares; `provider_event_id` is `raw["id"]`, which is per-instance.
  defp instance(source, attrs) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: @series_uid,
          calendar_integration_id: source.id,
          provider: :google,
          provider_calendar_id: "primary",
          summary: "TYMESLOT TEST weekly",
          all_day: false,
          recurring_event_id: @master_id,
          synced_at: ~U[2026-08-18 00:00:00Z]
        },
        attrs
      )
    )
  end

  # The 2026-08-28 occurrence as the live API returned it after cancellation:
  # status cancelled, and `start` equal to `originalStartTime` because a
  # cancellation does not move anything.
  defp cancelled_instance(source) do
    instance(source, %{
      provider_event_id: "#{@master_id}_20260828T140000Z",
      status: :cancelled,
      start_at: ~U[2026-08-28 14:00:00Z],
      end_at: ~U[2026-08-28 14:30:00Z],
      original_start_at: ~U[2026-08-28 14:00:00Z]
    })
  end

  # The 2026-09-11 occurrence, dragged from 14:00Z to 16:00Z. Kept alongside so
  # the two markers are exercised against each other rather than in isolation.
  defp moved_instance(source) do
    instance(source, %{
      provider_event_id: "#{@master_id}_20260911T140000Z",
      status: :confirmed,
      start_at: ~U[2026-09-11 16:00:00Z],
      end_at: ~U[2026-09-11 16:30:00Z],
      original_start_at: ~U[2026-09-11 14:00:00Z]
    })
  end

  defp enqueued do
    Enum.map(all_enqueued(worker: SyncLinkWriteBackWorker), & &1.args)
  end

  describe "report/2 detecting a cancelled occurrence" do
    test "a cancelled occurrence enqueues an upsert excepting its instant", %{
      source: source,
      link: link
    } do
      assert :ok == MovedOccurrence.report([cancelled_instance(source)], [link])

      assert [args] = enqueued()

      assert args["sync_link_id"] == link.id
      assert args["source_uid"] == @series_uid
      assert args["operation"] == "upsert"

      # A cancellation has an instant to free and no instant to block, so it
      # carries the original start and no new one. An RDATE here would re-book
      # the slot the organiser has just cleared.
      assert args["moved"] == [
               %{"original_start" => "2026-08-28T14:00:00Z", "new_start" => nil}
             ]
    end

    test "a cancelled and a moved occurrence in one batch both travel", %{
      source: source,
      link: link
    } do
      assert :ok ==
               MovedOccurrence.report(
                 [cancelled_instance(source), moved_instance(source)],
                 [link]
               )

      assert [args] = enqueued()

      assert args["moved"] == [
               %{"original_start" => "2026-08-28T14:00:00Z", "new_start" => nil},
               %{
                 "original_start" => "2026-09-11T14:00:00Z",
                 "new_start" => "2026-09-11T16:00:00Z"
               }
             ]
    end

    test "an ordinary unmoved occurrence still enqueues nothing", %{
      source: source,
      link: link
    } do
      # The guard that keeps this pass from firing on every event of every sync.
      # A confirmed occurrence sitting at its scheduled time is the common case.
      ordinary =
        instance(source, %{
          provider_event_id: "#{@master_id}_20260821T140000Z",
          status: :confirmed,
          start_at: ~U[2026-08-21 14:00:00Z],
          end_at: ~U[2026-08-21 14:30:00Z],
          original_start_at: ~U[2026-08-21 14:00:00Z]
        })

      assert :ok == MovedOccurrence.report([ordinary], [link])

      assert enqueued() == []
    end

    test "a cancelled occurrence of a series nobody mirrors enqueues nothing", %{
      user: user,
      source: source
    } do
      # No placeholder stands at the cancelled instant, because a target that
      # cannot expand a series never received one.
      outlook_target = insert(:calendar_integration, user: user, provider: "outlook")

      outlook_link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: outlook_target.id
        )

      {:ok, outlook_link} = CalendarSyncLinkQueries.get(outlook_link.id)

      assert :ok == MovedOccurrence.report([cancelled_instance(source)], [outlook_link])

      assert enqueued() == []
    end

    test "a cancelled occurrence is recorded for the organiser to read", %{
      source: source,
      link: link
    } do
      assert :ok == MovedOccurrence.report([cancelled_instance(source)], [link])

      assert {:ok, conflict} =
               CalendarSyncConflictQueries.last_of_kind(link.id, @series_uid, "occurrence_moved")

      assert conflict.detail["occurrences"] == [
               %{"original_start" => "2026-08-28T14:00:00Z", "new_start" => nil}
             ]
    end
  end

  describe "the placeholder the provider is handed" do
    # The outcome assertion. A correction computed correctly and dropped on the
    # way into the payload leaves the cancelled occurrence blocking its slot
    # while every row-level check passes.
    test "carries an EXDATE at the cancelled instant and no RDATE", %{
      user: user,
      source: source,
      link: link
    } do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, event_id ->
        assert event_id == @master_id

        {:ok, google_series_master(master_id: @master_id, rule: "RRULE:FREQ=WEEKLY;COUNT=5")}
      end)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-pid-1"}}
      end)

      source_event =
        google_series_instance(source, master_id: @master_id, timezone: "Etc/UTC")

      cancellation = [%{original_start: ~U[2026-08-28 14:00:00Z], new_start: nil}]

      assert :ok ==
               Engine.mirror(link, source_event, user.id, moved: cancellation)

      assert_received {:payload, payload}

      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;COUNT=5"

      assert "EXDATE;TZID=Etc/UTC:20260828T140000" in payload.recurrence_exception_lines

      # No RDATE: the occurrence went nowhere, and one here would block a slot
      # the organiser has just freed.
      refute Enum.any?(payload.recurrence_exception_lines, &String.starts_with?(&1, "RDATE"))
    end

    test "a cancellation and a move on one series produce three lines", %{
      user: user,
      source: source,
      link: link
    } do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok, google_series_master(master_id: @master_id, rule: "RRULE:FREQ=WEEKLY;COUNT=5")}
      end)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-pid-1"}}
      end)

      source_event =
        google_series_instance(source, master_id: @master_id, timezone: "Etc/UTC")

      corrections = [
        %{original_start: ~U[2026-08-28 14:00:00Z], new_start: nil},
        %{original_start: ~U[2026-09-11 14:00:00Z], new_start: ~U[2026-09-11 16:00:00Z]}
      ]

      assert :ok == Engine.mirror(link, source_event, user.id, moved: corrections)

      assert_received {:payload, payload}

      # The live placeholder's own lines, plus the cancellation that was missing
      # from them.
      assert "EXDATE;TZID=Etc/UTC:20260828T140000" in payload.recurrence_exception_lines
      assert "EXDATE;TZID=Etc/UTC:20260911T140000" in payload.recurrence_exception_lines
      assert "RDATE;TZID=Etc/UTC:20260911T160000" in payload.recurrence_exception_lines
    end
  end
end
