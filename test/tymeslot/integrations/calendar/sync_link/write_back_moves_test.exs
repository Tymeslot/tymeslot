defmodule Tymeslot.Integrations.Calendar.SyncLink.WriteBackMovesTest do
  @moduledoc """
  Moved occurrences travelling on the job that rewrites the placeholder.

  A move is visible only at the sync seam: the cache keeps one row per series
  and the moved instance is collapsed into it before the write-back job runs.
  So the moves have to reach the write on the job itself.

  The hazard is the same `replace` that makes this queue correct elsewhere. A
  later enqueue for the same `{link, source_uid}` overwrites a pending job's
  args, and an ordinary sync enqueues for every event it sees — so a plain
  enqueue arriving after one carrying moves would drop them, and the correction
  would be silently lost rather than deferred. These tests pin that it is not.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup do: linked_pair()

  defp job_args do
    [job] = all_enqueued(worker: SyncLinkWriteBackWorker)
    job.args
  end

  @moves [
    %{"original_start" => "2026-08-14T14:00:00Z", "new_start" => "2026-08-14T22:00:00Z"}
  ]

  describe "enqueue/4 with moves" do
    test "the moves travel on the job", %{link: link} do
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert, moved: @moves)

      args = job_args()

      assert args["operation"] == "upsert"
      assert args["moved"] == @moves
    end

    test "an ordinary enqueue carries no moves key at all", %{link: link} do
      # Additive: every existing caller must produce the args it always did, so
      # a job for an unmoved event is byte-identical to before.
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert)

      refute Map.has_key?(job_args(), "moved")
    end

    test "a plain enqueue drops pending moves, which is why the sweep opts in", %{link: link} do
      # The replace hazard, stated as it actually is rather than as a guarantee
      # the code does not make. `enqueue/3` runs once per event per link on every
      # sync, so looking up pending moves there would be a query per synced event
      # on every calendar — the cost the sync path avoids by fetching the mirror
      # set once per batch. The ordinary enqueue therefore does not preserve, and
      # a correction dropped this way is re-detected on the next sync that sees
      # the move.
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert, moved: @moves)
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert)

      refute Map.has_key?(job_args(), "moved")
    end

    test "an enqueue asking to preserve carries pending moves forward", %{link: link} do
      # What the reconcile sweep uses: it re-enqueues a series it already knows
      # about, one job at a time, so the lookup is affordable there and losing a
      # correction to its own repair pass would be perverse.
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert, moved: @moves)
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert, moved: :preserve)

      assert job_args()["moved"] == @moves
    end

    test "a later enqueue carrying fresh moves replaces the pending ones", %{link: link} do
      # The other direction: a newer detection is the current truth. Merging the
      # two sets would keep correcting a move the organiser has since undone.
      newer = [
        %{"original_start" => "2026-09-01T09:00:00Z", "new_start" => "2026-09-02T09:00:00Z"}
      ]

      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert, moved: @moves)
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert, moved: newer)

      assert job_args()["moved"] == newer
    end

    test "a delete arriving after moves still becomes a delete", %{link: link} do
      # The case the replace exists for. A withdrawal must not be turned back
      # into an upsert by the moves that preceded it.
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :upsert, moved: @moves)
      assert :ok == WriteBack.enqueue(link.id, "series-uid", :delete)

      assert job_args()["operation"] == "delete"
    end
  end
end
