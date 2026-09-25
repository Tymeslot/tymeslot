defmodule Tymeslot.Repo.Migrations.WidenLocationOnMeetings do
  use Ecto.Migration

  def change do
    # `meetings.location` has been Ecto's default :string — varchar(255) —
    # since 20250701180112, when nothing ever wrote a long value to it. A
    # meeting type's locations changed that: the string is now composed from
    # a host-authored label (up to 120 characters) and its details (up to
    # 500), so "Our office (12 High Street, …)" can reach 625. At varchar(255)
    # a host with a long address would have every booking against that
    # location fail at the database rather than at any validation they could
    # see.
    #
    # Widening varchar -> text is a catalogue-only change in PostgreSQL: no
    # table rewrite, no scan, only a brief metadata lock. This mirrors
    # 20260902120000's widening of meetings.decline_reason.
    alter table(:meetings) do
      # excellent_migrations:safety-assured-for-next-line column_type_changed
      modify(:location, :text, from: :string)
    end
  end
end
