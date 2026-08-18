defmodule Tymeslot.Integrations.Calendar.SyncLink.RemirrorTest do
  @moduledoc """
  Whether an edit changes what a link's placeholders *say*, and the fan-out that
  follows when it does.

  A presentation change is the one edit whose effect is invisible until the
  placeholders are rewritten: the row stores the new tier immediately, and every
  busy block on the target goes on showing the old one until something re-sends
  it. Nothing else does — the reconcile sweep compares source events against
  mappings, and neither has changed.

  As with `TargetMove`, the tests come in pairs. Answering `true` for everything
  re-sends every placeholder on every save; answering `false` for everything
  leaves a tier change stored and never applied, which is exactly the defect
  this module was written to close.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Remirror
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  defp enqueued_pairs do
    all_enqueued(worker: SyncLinkWriteBackWorker)
    |> Enum.map(&{&1.args["sync_link_id"], &1.args["source_uid"], &1.args["operation"]})
    |> MapSet.new()
  end

  describe "presentation_change?/2 — what the placeholders say" do
    setup do: linked_pair()

    test "a new privacy tier changes it", %{link: link} do
      assert Remirror.presentation_change?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{privacy_tier: "full_passthrough"})
             )
    end

    test "a new generic label changes it", %{link: link} do
      cs =
        CalendarSyncLinkSchema.changeset(link, %{
          privacy_tier: "generic_label",
          generic_label: "Reserved"
        })

      assert Remirror.presentation_change?(link, cs)
    end

    test "a new mirror colour changes it", %{link: link} do
      assert Remirror.presentation_change?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{mirror_colour: "tomato"})
             )
    end
  end

  describe "presentation_change?/2 — what it must not react to" do
    setup do: linked_pair()

    test "pausing does not change what a placeholder says", %{link: link} do
      # Pausing deliberately leaves existing placeholders standing and unaltered.
      refute Remirror.presentation_change?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{enabled: false})
             )
    end

    test "re-pointing is not a presentation change", %{user: user, link: link} do
      # A move is `TargetMove`'s question and gets a teardown, not a rewrite.
      # Answering true here as well would re-send placeholders that are about to
      # be withdrawn.
      elsewhere = insert(:calendar_integration, user: user, provider: "google")

      refute Remirror.presentation_change?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{target_integration_id: elsewhere.id})
             )
    end

    test "an empty edit changes nothing", %{link: link} do
      refute Remirror.presentation_change?(link, CalendarSyncLinkSchema.changeset(link, %{}))
    end

    test "re-submitting the stored tier is not a change", %{link: link} do
      refute Remirror.presentation_change?(
               link,
               CalendarSyncLinkSchema.changeset(link, %{privacy_tier: link.privacy_tier})
             )
    end
  end

  describe "enqueue_remirror/1" do
    setup do: linked_pair()

    test "enqueues one upsert per mapping the link holds", %{link: link} do
      mirror_for_link(link, source_uid: "src-1")
      mirror_for_link(link, source_uid: "src-2")

      assert :ok == Remirror.enqueue_remirror(link)

      assert enqueued_pairs() ==
               MapSet.new([
                 {link.id, "src-1", "upsert"},
                 {link.id, "src-2", "upsert"}
               ])
    end

    test "a pending correction survives a presentation change", %{link: link} do
      # Same hazard as the reconcile sweep: this re-enqueues a series it already
      # knows about, and `replace` would swap away the moves a pending job
      # carries. A tier change must not silently undo a correction.
      mirror_for_link(link, source_uid: "series-uid")

      moves = [
        %{"original_start" => "2026-08-14T14:00:00Z", "new_start" => "2026-08-14T22:00:00Z"}
      ]

      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert, moved: moves)
      assert :ok == Remirror.enqueue_remirror(link)

      [job] = all_enqueued(worker: SyncLinkWriteBackWorker)

      assert job.args["moved"] == moves
    end

    test "a link holding no mappings enqueues nothing", %{link: link} do
      assert :ok == Remirror.enqueue_remirror(link)

      assert Enum.empty?(all_enqueued(worker: SyncLinkWriteBackWorker))
    end

    test "a paused link enqueues nothing at all", %{link: link} do
      mirror_for_link(link, source_uid: "src-1")
      {:ok, paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      assert :ok == Remirror.enqueue_remirror(paused)

      # The worker would discard each job as `:link_disabled` anyway, so this is
      # a refusal to insert rows and log discards rather than a correctness
      # guard — but it is the difference between a paused link costing nothing
      # and a paused link costing one job per placeholder on every save.
      assert Enum.empty?(all_enqueued(worker: SyncLinkWriteBackWorker))
    end

    test "another link's mappings are left alone", %{user: user, source: source, link: link} do
      # Two links out of one source, so the same source_uid carries a mapping on
      # each. A re-mirror scoped by source rather than by link would re-send both
      # and rewrite the other link's placeholders under this link's tier.
      {_other_target, other} = extra_target_link(%{user: user, source: source})

      mirror_for_link(link, source_uid: "src-1")
      mirror_for_link(other, source_uid: "src-1")

      assert :ok == Remirror.enqueue_remirror(link)

      assert enqueued_pairs() == MapSet.new([{link.id, "src-1", "upsert"}])
    end
  end
end
