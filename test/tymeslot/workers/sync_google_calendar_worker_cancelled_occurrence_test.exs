defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerCancelledOccurrenceTest do
  @moduledoc """
  A cancelled *occurrence* of a recurring series arriving on the delta, and the
  two very different things it must not be mistaken for.

  ## Why the worker is the right level for this

  `safe_process_events/3` splits the batch on `status == "cancelled"` before
  normalising, and hands every cancelled item to `Sync.reconcile_deletions/3`.
  That is exactly right for a cancelled one-off, and wrong for a cancelled
  occurrence, because the two are told apart by a field the split does not read:
  a `recurringEventId`.

  Under `singleEvents=true` every occurrence of a series shares the master's
  `iCalUID` — measured on the live calendar as
  `56km0ibouqobmlmh3g5ptdmp28@google.com` for all five — and
  `reconcile_deletions/3` withdraws by uid. So one cancelled occurrence took the
  deletion path under the *series'* uid: it deleted the series' only cache row
  and enqueued a `delete` that withdraws the whole placeholder, removing four
  occurrences that are still happening in order to free one that is not.

  The detection built in `SyncLink.MovedOccurrence` cannot see any of it,
  because the occurrence never reaches normalisation and so never reaches
  `post_commit_reconciliation/2` where per-instance markers are read.

  ## The bodies here, and the one that was wrong

  The confirmed occurrence is the API's own response, fetched from the
  organiser's calendar rather than composed.

  The cancelled one was not. It was written from a `get_event` response — which
  does carry `iCalUID`, `start` and `end` — and presented as the delta shape.
  The delta shape is a **tombstone**: `id`, `etag`, `kind`, `status`,
  `recurringEventId`, `originalStartTime`, and nothing else. No timing, and no
  `iCalUID`.

  That invented field was doing the work the code could not: it supplied the
  series uid that `uid: raw["iCalUID"] || raw["id"]` cannot derive from a real
  tombstone, so every assertion below passed while production dropped the
  cancellation at `CalendarEvent.new/1` and alerted about it. The fixture now
  comes from `SyncLinkTestHelpers.google_delta_cancellation/2`, transcribed from
  the captured body.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.GoogleDeltaFixtures

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  @master_id "56km0ibouqobmlmh3g5ptdmp28"
  @series_uid "56km0ibouqobmlmh3g5ptdmp28@google.com"

  defp cancelled_occurrence,
    do: google_delta_cancellation(@master_id, "2026-08-28T14:00:00Z")

  defp surviving_occurrence do
    %{
      "id" => "#{@master_id}_20260904T140000Z",
      "iCalUID" => @series_uid,
      "recurringEventId" => @master_id,
      "status" => "confirmed",
      "summary" => "TYMESLOT TEST weekly",
      "start" => %{"dateTime" => "2026-09-04T14:00:00Z", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-09-04T14:30:00Z", "timeZone" => "UTC"},
      "originalStartTime" => %{"dateTime" => "2026-09-04T14:00:00Z", "timeZone" => "UTC"}
    }
  end

  defp cancelled_one_off do
    %{
      "id" => "standalone-event-1",
      "iCalUID" => "standalone-event-1@google.com",
      "status" => "cancelled",
      "summary" => "Lunch"
    }
  end

  defp run(integration, events) do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: events, next_sync_token: "new-token"}}
    end)

    perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})
  end

  defp write_back_args do
    Enum.map(all_enqueued(worker: SyncLinkWriteBackWorker), & &1.args)
  end

  describe "a cancelled occurrence of a mirrored series" do
    setup do
      user = insert(:user)

      source =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          google_sync_token: "valid-token"
        )

      target = insert(:calendar_integration, user: user, provider: "google")

      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

      %{source: source}
    end

    # The delta carries only what changed. Cancelling one occurrence therefore
    # arrives as a batch of exactly one cancelled instance, with no sibling
    # beside it to re-insert the row the deletion path removes — which is why
    # this is the shape the damage shows up in, and why a test that includes a
    # surviving occurrence in the same batch hides it entirely.
    test "arriving alone does not withdraw the whole placeholder", %{source: source} do
      insert(:provider_calendar_event,
        calendar_integration: source,
        uid: @series_uid,
        provider: "google",
        provider_event_id: "#{@master_id}_20260918T140000Z",
        recurring_event_id: @master_id
      )

      assert :ok = run(source, [cancelled_occurrence()])

      operations = write_back_args() |> Enum.map(& &1["operation"]) |> Enum.uniq()

      # A `delete` here removes the placeholder for the entire series — the four
      # occurrences still happening as well as the one that is not.
      refute "delete" in operations
    end

    test "arriving alone does not delete the series' cache row", %{source: source} do
      insert(:provider_calendar_event,
        calendar_integration: source,
        uid: @series_uid,
        provider: "google",
        provider_event_id: "#{@master_id}_20260918T140000Z",
        recurring_event_id: @master_id
      )

      assert :ok = run(source, [cancelled_occurrence()])

      # The series is one cache row keyed on the shared uid. Deleting it for one
      # cancelled occurrence loses the whole series from availability.
      assert Repo.get_by(ProviderCalendarEventSchema,
               calendar_integration_id: source.id,
               uid: @series_uid
             )
    end

    test "enqueues an upsert excepting the cancelled instant", %{source: source} do
      assert :ok = run(source, [cancelled_occurrence(), surviving_occurrence()])

      assert [args] =
               Enum.filter(write_back_args(), &(&1["source_uid"] == @series_uid))

      assert args["operation"] == "upsert"

      assert args["moved"] == [
               %{"original_start" => "2026-08-28T14:00:00Z", "new_start" => nil}
             ]
    end
  end

  describe "a cancelled one-off event" do
    setup do
      user = insert(:user)

      source =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          google_sync_token: "valid-token"
        )

      target = insert(:calendar_integration, user: user, provider: "google")

      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

      %{source: source}
    end

    test "is still withdrawn, which is the path that must not regress", %{source: source} do
      # The deletion route is correct for an event that names no series: nothing
      # remains of it, so the placeholder should go entirely.
      assert :ok = run(source, [cancelled_one_off()])

      assert [args] = write_back_args()

      assert args["operation"] == "delete"
      assert args["source_uid"] == "standalone-event-1@google.com"
    end
  end
end
