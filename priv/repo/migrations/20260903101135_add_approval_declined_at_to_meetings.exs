defmodule Tymeslot.Repo.Migrations.AddApprovalDeclinedAtToMeetings do
  use Ecto.Migration

  # The one field that means "the host refused this request".
  #
  # `approval_resolved_at` cannot carry that meaning, although three call sites
  # originally read it that way: it is stamped by every host answer, an
  # approval included. A booking approved and then cancelled in the ordinary
  # way therefore looked identical to a declined one, and was reported as a
  # decline on the `meeting.cancelled` webhook, on the invitee's request page
  # and on the paid return page.
  #
  # Nullable and unbackfilled on purpose. No production row can be a decline
  # yet: the approval gate ships in this release, so every existing meeting
  # predates the only code that can set this. Adding a nullable column with no
  # default is a catalogue-only change.
  def change do
    alter table(:meetings) do
      add(:approval_declined_at, :utc_datetime)
    end
  end
end
