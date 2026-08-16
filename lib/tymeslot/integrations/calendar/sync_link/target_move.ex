defmodule Tymeslot.Integrations.Calendar.SyncLink.TargetMove do
  @moduledoc """
  Whether an edit to a link invalidates the placeholders it has already
  written.

  ## Why this is a question at all

  Most edits to a link are cosmetic: a privacy tier, a label, a colour. They
  change what the *next* placeholder says and leave every existing one exactly
  where it is, on a calendar that is still the right calendar. Three fields are
  not cosmetic, because each of them makes every mapping row a statement about
  a relationship that no longer exists:

  - `target_integration_id` — the placeholders are on the old calendar, and
    nothing about the link now points there.
  - `target_calendar_id` — the same, one level down. Google and Outlook honour
    a calendar id on write, so a link naming a secondary calendar put its
    placeholders there rather than on the integration's default.
  - `source_integration_id` — the placeholders themselves have not moved, but
    every mapping is keyed on a `source_uid` from a calendar the link no longer
    reads. Those uids will not be found in the new source, so the reconcile
    sweep would read each mapping as a source that has been deleted and enqueue
    a withdrawal one by one; and until it did, the target would carry busy
    blocks mirroring a calendar nobody linked to it. Treating it as a move
    withdraws them at once, deliberately and while the organiser is watching,
    rather than as a trickle of deletions half an hour later.

  ## Why the comparison runs against the changeset, not the attributes

  The attributes an organiser submits are not what gets stored.
  `CalendarSyncLinkSchema.clear_calendar_id_when_target_cannot_choose/1` nulls
  `target_calendar_id` for a CalDAV target, which ignores it and always writes
  to the primary path — so a form that faithfully re-submits the id it was
  handed would look like `nil` → `"personal"`, a move, on every single save. The
  link would tear down its placeholders each time it was edited, and rebuild
  them, and the organiser would see the busy blocks flicker for no reason they
  could name.

  Asking `Ecto.Changeset.apply_changes/1` instead compares the row as it stands
  against the row as it will stand, with every normalisation already applied.
  It also means this module does not carry a second copy of the CalDAV rule to
  drift out of step with the changeset's.

  A field the attributes never mention is unchanged by construction: it appears
  in neither the changes nor differently in the applied struct.
  """

  import Ecto.Changeset, only: [apply_changes: 1]

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema

  @invalidating_fields [:source_integration_id, :target_integration_id, :target_calendar_id]

  @doc """
  Whether applying `changeset` to `link` re-points it at a different calendar,
  or at a different source.

  Expects a changeset that has already been validated: an invalid one has not
  earned a teardown, and `apply_changes/1` on it would compare against values
  that are never going to be stored.
  """
  @spec repoint?(CalendarSyncLinkSchema.t(), Ecto.Changeset.t()) :: boolean()
  def repoint?(%CalendarSyncLinkSchema{} = link, %Ecto.Changeset{} = changeset) do
    applied = apply_changes(changeset)

    Enum.any?(@invalidating_fields, fn field ->
      Map.fetch!(applied, field) != Map.fetch!(link, field)
    end)
  end
end
