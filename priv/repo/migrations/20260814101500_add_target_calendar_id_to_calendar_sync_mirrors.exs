defmodule Tymeslot.Repo.Migrations.AddTargetCalendarIdToCalendarSyncMirrors do
  use Ecto.Migration

  # Which calendar *within* the target integration the placeholder was written
  # onto. The integration alone does not locate it: Google and Outlook honour a
  # `calendar_id` on write, so a link naming a secondary calendar puts its
  # placeholders there rather than on the integration's default booking
  # calendar.
  #
  # Until now every write and every delete built that calendar id from the
  # link's *current* `target_calendar_id`, which is only correct while the link
  # never moves. An organiser who re-points a link leaves the existing
  # placeholders on the old calendar, and the delete then asks the new one about
  # them — drawing a 404 the engine reads as "already gone", dropping the
  # mapping row, and stranding a busy block on the organiser's calendar with
  # nothing left that can name it. Recording the calendar at write time is what
  # makes the delete addressable after the link has changed.
  #
  # Nullable and deliberately not backfilled. `nil` means "wherever the link
  # points", which is exactly what the delete paths did for every row written
  # before this column — so an existing row keeps its current behaviour instead
  # of acquiring a claim about a calendar nobody recorded. The CalDAV family
  # ignores `calendar_id` and always writes to the primary path, so `nil` is
  # also the permanently correct value there.
  def change do
    alter table(:calendar_sync_mirrors) do
      add(:target_calendar_id, :string)
    end
  end
end
