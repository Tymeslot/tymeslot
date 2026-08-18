defmodule TymeslotWeb.Dashboard.SyncLinks.ConflictLabels do
  @moduledoc """
  The organiser-facing wording for a recorded mirror divergence.

  `calendar_sync_conflicts` stores a `kind` and a `resolution` as short codes
  the engine writes — `"mirror_edited"`, `"deletion_won"`. Those are precise
  and meaningless to anyone who has not read the engine, so every one is
  translated into a sentence describing what happened to the organiser's
  calendar rather than what the engine called it.

  Lifted out of `SyncLinksSettingsComponent` because it is a translation table
  and nothing else: no socket, no assigns, no state. Leaving it inline pushed
  that module past the line budget the analyser enforces, and the seam is a
  real one — the panel decides *when* to show a conflict, this decides what it
  says.

  Every clause has a catch-all, deliberately. A kind or resolution added to the
  engine and not yet added here renders a vaguer sentence rather than crashing
  the panel that was showing it.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  @spec conflict_kind_label(String.t()) :: String.t()
  # What happened, in the organiser's terms rather than the schema's. The stored
  # value is a code the engine writes; "mirror_edited" on a page means nothing to
  # someone who has never read the engine.
  def conflict_kind_label("mirror_edited"),
    do:
      dgettext(
        "dashboard_integrations",
        "The busy block was edited on the target calendar."
      )

  def conflict_kind_label("both_changed"),
    do:
      dgettext(
        "dashboard_integrations",
        "The original event and its busy block both changed."
      )

  def conflict_kind_label("delete_race"),
    do:
      dgettext(
        "dashboard_integrations",
        "The original event was deleted while the placeholder was edited."
      )

  def conflict_kind_label("write_failed"),
    do:
      dgettext(
        "dashboard_integrations",
        "The busy block could not be written to the target calendar."
      )

  # Both halves of the failure, because naming only one of them misleads. The
  # instinct is to call this over-blocking, and the freed slot is the visible
  # symptom — but the slot the occurrence moved *to* is unblocked and can be
  # booked over a meeting that is genuinely happening, which is the more
  # damaging half and the one nobody looks for unless told.
  def conflict_kind_label("occurrence_moved"),
    do:
      dgettext(
        "dashboard_integrations",
        "One occurrence of this repeating event was moved. The busy block still sits at its original time, and no busy block covers its new time — so that slot can be double-booked."
      )

  # No longer produced — placeholders now carry the series' cancelled
  # occurrences — but historical rows are still rendered, because the table is
  # append-only and this was true of the placeholder at the time it was written.
  # The wording is past tense for that reason: an organiser reading a row from
  # last month must not go looking for a gap that today's placeholder does not
  # have.
  def conflict_kind_label("series_exceptions"),
    do:
      dgettext(
        "dashboard_integrations",
        "The repeating busy block did not reflect cancelled occurrences at the time."
      )

  # The refusal that used to be an Oban discard reason and nothing else. Both
  # halves are stated because either alone misleads: "not mirrored" on its own
  # reads as a cosmetic gap, when the consequence is that every occurrence of a
  # meeting that is genuinely happening sits in a slot the organiser's booking
  # page will happily sell.
  #
  # Deliberately does not name which end or which provider, though the row
  # carries both. The sentence has to be true for every reader, and "your
  # Outlook calendar cannot do this" invites an organiser to go looking for a
  # setting to change on a calendar where none exists. What they can act on is
  # which repeating event is unprotected, and the source UID beside this line is
  # that.
  def conflict_kind_label("series_unsupported"),
    do:
      dgettext(
        "dashboard_integrations",
        "This repeating event is not being mirrored: one of the two calendars on this link cannot handle a repeating event. None of its occurrences is blocked on the target calendar, so those times can be booked over."
      )

  # A kind this version does not know how to name is still shown, because the
  # row's date and event are useful on their own and a silently dropped entry
  # would make the history lie about how many there were.
  def conflict_kind_label(_kind),
    do: dgettext("dashboard_integrations", "The two calendars differed.")

  @spec conflict_resolution_label(String.t()) :: String.t()
  def conflict_resolution_label("source_won"),
    do: dgettext("dashboard_integrations", "The original event was kept.")

  def conflict_resolution_label("deletion_won"),
    do: dgettext("dashboard_integrations", "The busy block was removed.")

  def conflict_resolution_label("skipped"),
    do: dgettext("dashboard_integrations", "Nothing was changed on the target calendar.")

  def conflict_resolution_label(_resolution),
    do: dgettext("dashboard_integrations", "The difference was resolved automatically.")
end
