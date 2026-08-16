defmodule Tymeslot.Integrations.Calendar.SyncLinkPresentationChangeTest do
  @moduledoc """
  Editing what a placeholder *says*, and the placeholders already written.

  A privacy tier, a label and a colour are the three fields that change the
  content of every placeholder a link holds while leaving each of them exactly
  where it is. Nothing else notices: the push path fires on a *source event*
  changing, and the reconcile sweep compares the source's `provider_updated_at`
  against the mapping — neither of which moves when the organiser edits the
  link. So a link switched from `busy_only` to `generic_label` kept saying
  "Busy" until somebody happened to edit the source event, which for a standing
  weekly meeting is never.

  The counterpart to the re-point case in `sync_link_test.exs`: that one is the
  edit that invalidates *where* the placeholders are, this is the edit that
  invalidates *what they say*.

  Assertions run to the provider call, not to the enqueue. A job carrying the
  right arguments proves nothing about the label the organiser will see —
  the payload is rebuilt from the link at perform time, so the end-to-end test
  is the one that says the feature works.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.SyncLink
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    # The write-back worker charges a per-target-account budget from a
    # process-independent ETS bucket that leaks between tests: without this, a
    # neighbouring test that spent it makes the end-to-end write snooze instead
    # of reaching the provider.
    RateLimiter.clear_all()

    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "google")

    {:ok, link} =
      SyncLink.create_link(user.id, %{
        "source_integration_id" => source.id,
        "target_integration_id" => target.id
      })

    {:ok, user: user, source: source, target: target, link: link}
  end

  # The source uids the link has queued a rewrite for, sorted so the assertion
  # is about the set rather than the order `list_for_link/1` happened to return.
  defp enqueued_upserts do
    [worker: SyncLinkWriteBackWorker]
    |> all_enqueued()
    |> Enum.filter(&(&1.args["operation"] == "upsert"))
    |> Enum.map(& &1.args["source_uid"])
    |> Enum.sort()
  end

  describe "update_link/3 rewrites the placeholders a presentation change invalidates" do
    # No provider `expect` in these: the enqueue is the context's whole job, and
    # `verify_on_exit!` fails the test if the edit reaches a calendar
    # synchronously. A presentation change writes nothing itself — it hands the
    # writes to the queue, where the budget paces them.
    test "a privacy tier change enqueues an upsert for every mapping", ctx do
      %{user: user, link: link} = ctx
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")
      mirror_for_link(link, source_uid: "src-2", target_uid: "mirror-2")
      mirror_for_link(link, source_uid: "src-3", target_uid: "mirror-3")

      assert {:ok, updated} =
               SyncLink.update_link(user.id, link.id, %{
                 "privacy_tier" => "generic_label",
                 "generic_label" => "Busy elsewhere"
               })

      assert updated.privacy_tier == "generic_label"
      assert enqueued_upserts() == ["src-1", "src-2", "src-3"]
    end

    test "a generic label change alone enqueues them too", ctx do
      %{user: user, link: link} = ctx

      {:ok, link} =
        SyncLink.update_link(user.id, link.id, %{
          "privacy_tier" => "generic_label",
          "generic_label" => "Busy elsewhere"
        })

      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")
      mirror_for_link(link, source_uid: "src-2", target_uid: "mirror-2")

      assert {:ok, updated} =
               SyncLink.update_link(user.id, link.id, %{"generic_label" => "Away"})

      assert updated.generic_label == "Away"
      assert enqueued_upserts() == ["src-1", "src-2"]
    end

    test "a mirror colour change alone enqueues them too", ctx do
      %{user: user, link: link} = ctx
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")
      mirror_for_link(link, source_uid: "src-2", target_uid: "mirror-2")

      assert {:ok, updated} = SyncLink.update_link(user.id, link.id, %{"mirror_colour" => "sage"})

      assert updated.mirror_colour == "sage"
      assert enqueued_upserts() == ["src-1", "src-2"]
    end

    # `last_reconciled_at` is the sweep's own bookkeeping and says nothing about
    # what a placeholder says. An edit touching only that must not put the
    # link's whole mapping set through the provider.
    test "a field that is neither presentation nor a re-point enqueues nothing", ctx do
      %{user: user, link: link} = ctx
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")

      assert {:ok, _updated} =
               SyncLink.update_link(user.id, link.id, %{
                 "last_reconciled_at" => DateTime.utc_now()
               })

      assert enqueued_upserts() == []
    end

    # The whole point of an idempotent save. The dashboard form re-submits every
    # field it renders, so a save that changed nothing would otherwise rewrite
    # every placeholder on the link — a burst of provider writes for an edit the
    # organiser did not make.
    test "saving the same values again enqueues nothing", ctx do
      %{user: user, link: link} = ctx

      {:ok, link} =
        SyncLink.update_link(user.id, link.id, %{
          "privacy_tier" => "generic_label",
          "generic_label" => "Busy elsewhere",
          "mirror_colour" => "sage"
        })

      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")
      Repo.delete_all(Oban.Job)

      assert {:ok, _updated} =
               SyncLink.update_link(user.id, link.id, %{
                 "privacy_tier" => "generic_label",
                 "generic_label" => "Busy elsewhere",
                 "mirror_colour" => "sage"
               })

      assert enqueued_upserts() == []
    end

    # A paused link's writes are discarded by the worker on arrival, so
    # enqueueing them is pure churn: rows inserted, jobs executed, provider
    # never touched. Resuming the link is what refills the target, through the
    # reconcile sweep.
    test "a paused link enqueues nothing", ctx do
      %{user: user, link: link} = ctx
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")
      {:ok, _paused} = SyncLink.toggle_enabled(user.id, link.id, false)

      assert {:ok, updated} =
               SyncLink.update_link(user.id, link.id, %{
                 "privacy_tier" => "generic_label",
                 "generic_label" => "Busy elsewhere"
               })

      refute updated.enabled
      assert enqueued_upserts() == []
    end

    test "a link holding no mappings enqueues nothing", ctx do
      %{user: user, link: link} = ctx

      assert {:ok, _updated} =
               SyncLink.update_link(user.id, link.id, %{"mirror_colour" => "sage"})

      assert enqueued_upserts() == []
    end

    # An edit refused by the changeset stored nothing, so the placeholders still
    # match the link exactly as it stands. Rewriting them would send the *old*
    # presentation to the provider for every mapping on the link.
    test "an edit the changeset refuses enqueues nothing", ctx do
      %{user: user, link: link} = ctx
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")

      assert {:error, changeset} =
               SyncLink.update_link(user.id, link.id, %{"privacy_tier" => "invented_tier"})

      refute changeset.valid?
      assert enqueued_upserts() == []
    end
  end

  describe "update_link/3 when a re-point and a presentation change arrive together" do
    test "the re-point wins and no re-mirror is enqueued", ctx do
      %{user: user, link: link} = ctx
      elsewhere = insert(:calendar_integration, user: user, provider: "google")
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert {:ok, updated} =
               SyncLink.update_link(user.id, link.id, %{
                 "target_integration_id" => elsewhere.id,
                 "privacy_tier" => "generic_label",
                 "generic_label" => "Busy elsewhere"
               })

      assert updated.target_integration_id == elsewhere.id
      assert updated.privacy_tier == "generic_label"

      # Teardown dropped the mapping rows, so there is nothing left to rewrite:
      # an enqueue here would name a mapping that no longer exists, and the job
      # would find no cached source and discard. The reconcile sweep refills the
      # new target from scratch, under the presentation just saved.
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
      assert enqueued_upserts() == []
    end

    test "a failed teardown saves nothing, so nothing is re-mirrored either", ctx do
      %{user: user, link: link} = ctx
      elsewhere = insert(:calendar_integration, user: user, provider: "google")
      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} =
               SyncLink.update_link(user.id, link.id, %{
                 "target_integration_id" => elsewhere.id,
                 "privacy_tier" => "generic_label",
                 "generic_label" => "Busy elsewhere"
               })

      assert enqueued_upserts() == []
    end
  end

  describe "the placeholder the organiser sees" do
    # The test that matters. Storing the tier is not the feature; the block on
    # the target calendar saying the new thing is. Every assertion above stops
    # at the enqueue, and an enqueue proves nothing about the payload — it is
    # rebuilt from the link when the job runs, so only running the job says
    # whether the organiser's label ever reaches the provider.
    test "a tier change rewrites the placeholder with the new label", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      insert(:provider_calendar_event,
        calendar_integration: source,
        uid: "src-1",
        summary: "Board meeting",
        provider: source.provider,
        provider_event_id: "source-pid-1",
        all_day: false,
        start_at: ~U[2026-07-03 09:00:00Z],
        end_at: ~U[2026-07-03 10:00:00Z]
      )

      # The uid the engine derives from the link and source uid, not an
      # invented one: the rewrite is addressed there, and a row carrying
      # anything else describes a placeholder the write would never reach.
      target_uid = Engine.target_uid_for(link.id, "src-1")
      mirror_for_link(link, source_uid: "src-1", target_uid: target_uid)

      assert {:ok, _updated} =
               SyncLink.update_link(user.id, link.id, %{
                 "privacy_tier" => "generic_label",
                 "generic_label" => "Busy elsewhere"
               })

      assert [%{args: %{"source_uid" => "src-1", "operation" => "upsert"}} = job] =
               all_enqueued(worker: SyncLinkWriteBackWorker)

      test_pid = self()

      # The mapping row already exists, so the engine updates rather than
      # creates. An OAuth provider answers an update with `{:ok, event}`; the
      # CalDAV family answers a bare `:ok`, and the id the mapping keeps differs
      # between the two — this is the Google shape, matching the target above.
      expect(Tymeslot.CalendarMock, :update_event, fn uid, payload, context ->
        send(test_pid, {:written, uid, payload.summary, context})
        {:ok, %{uid: uid}}
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, job.args)

      assert_received {:written, ^target_uid, summary, {target_id, user_id}}

      # The whole point. The placeholder now says what the organiser chose,
      # rather than the "Busy" it was written with — and it says it because the
      # payload is rebuilt from the link when the job runs.
      assert summary == "Busy elsewhere"
      assert target_id == target.id
      assert user_id == user.id
    end
  end
end
