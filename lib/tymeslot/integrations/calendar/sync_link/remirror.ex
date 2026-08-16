defmodule Tymeslot.Integrations.Calendar.SyncLink.Remirror do
  @moduledoc """
  Whether an edit to a link changes what its existing placeholders *say*, and
  the rewrite that follows if it does.

  The sibling of `SyncLink.TargetMove`, and the pair carves every edit in two.
  A re-point invalidates *where* the placeholders are and can only be answered
  by withdrawing them; a presentation change invalidates *what they say* while
  each one stays exactly where it is, and is answered by rewriting them in
  place. Three fields belong to this half:

  - `privacy_tier` — decides whether a placeholder reads "Busy", the link's own
    label, or the source event's summary.
  - `generic_label` — the label itself, which only the `generic_label` tier
    renders. It is compared regardless of tier: an organiser who edits the
    label and switches the tier in one save has changed both, and a save that
    only corrected a typo in the label of a link already on that tier is the
    ordinary case.
  - `mirror_colour` — painted onto the placeholder by a separate provider call,
    but reached through the same write.

  ## Why this needs a mechanism at all

  Nothing else notices. The push path enqueues a mirror write when a *source
  event* changes, and `SyncLinkReconcileWorker` compares the source's
  `provider_updated_at` against the mapping's `source_updated_at` — the link
  row is not an input to either. So a link switched from `busy_only` to
  `generic_label` kept its placeholders saying "Busy" until somebody happened
  to edit the source event, which for a standing weekly meeting is never. The
  organiser sees the setting stored and the calendar unchanged, with nothing to
  tell them the two disagree.

  ## Why the comparison runs against the changeset, not the attributes

  The same reason `TargetMove` does, and the same failure if it does not: the
  dashboard form re-submits every field it renders, so comparing the submitted
  attributes against the row would read every idempotent save as a change and
  put the link's whole mapping set through the provider for an edit the
  organiser did not make. `Ecto.Changeset.apply_changes/1` compares the row as
  it stands against the row as it will stand, with the changeset's own
  normalisations already applied, so a field that did not actually move is
  identical on both sides.

  ## Why the enqueue is best-effort

  `WriteBack.enqueue/3` already swallows its own failures — see its moduledoc —
  and this deliberately does not reintroduce them. The edit is saved before a
  single job is inserted, and a failed insert has not unsaved it. Answering the
  organiser with an error for a row that *did* change would invite them to save
  again, which changes nothing and enqueues nothing, because the second save is
  idempotent and this module correctly reads it as no change at all.

  A mirror that never got its job is not lost either: `SyncLinkReconcileWorker`
  re-derives the write from the mapping rows within half an hour. Late is the
  accepted cost; refusing an edit that already happened is not.
  """

  import Ecto.Changeset, only: [apply_changes: 1]

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack

  @presentation_fields [:privacy_tier, :generic_label, :mirror_colour]

  @doc """
  Whether applying `changeset` to `link` changes what its placeholders say.

  Expects a validated changeset: an invalid one stores nothing, so its
  placeholders still match the link exactly as it stands, and rewriting them
  would send the *old* presentation to the provider for every mapping.
  """
  @spec presentation_change?(CalendarSyncLinkSchema.t(), Ecto.Changeset.t()) :: boolean()
  def presentation_change?(%CalendarSyncLinkSchema{} = link, %Ecto.Changeset{} = changeset) do
    applied = apply_changes(changeset)

    Enum.any?(@presentation_fields, fn field ->
      Map.fetch!(applied, field) != Map.fetch!(link, field)
    end)
  end

  @doc """
  Enqueues an `:upsert` for every mapping the link holds, so each placeholder is
  rewritten under the presentation just saved.

  `:upsert` rather than a rewrite of its own: the payload is rebuilt from the
  link when `SyncLinkWriteBackWorker` runs, so the job needs to carry nothing
  but the pair it names, and the same job that handles an edited source event
  handles this. `WriteBack`'s `unique` on `[:sync_link_id, :source_uid]`
  collapses a re-mirror against a write already pending for the same event
  rather than queueing a second one.

  Takes the link *as saved* rather than as it was: a paused link is asked to
  write nothing at all. The worker would discard each job as `:link_disabled`
  anyway, so this is not a correctness guard but a refusal to insert rows,
  execute jobs and log discards for a link whose organiser has said not to send
  anything. Resuming it is what refills the target, through the sweep.

  Answers `:ok` regardless — see the moduledoc on why an enqueue failure does
  not unsave the edit that preceded it.
  """
  @spec enqueue_remirror(CalendarSyncLinkSchema.t()) :: :ok
  def enqueue_remirror(%CalendarSyncLinkSchema{enabled: false}), do: :ok

  def enqueue_remirror(%CalendarSyncLinkSchema{} = link) do
    link.id
    |> CalendarSyncMirrorQueries.list_for_link()
    |> Enum.each(&WriteBack.enqueue(link.id, &1.source_uid, :upsert))
  end
end
