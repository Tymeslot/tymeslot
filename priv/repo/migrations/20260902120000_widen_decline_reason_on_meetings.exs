defmodule Tymeslot.Repo.Migrations.WidenDeclineReasonOnMeetings do
  use Ecto.Migration

  def change do
    # `Tymeslot.Validation.Constraints.decline_reason_max_length/0` promises
    # 500 characters, but 20260819122155 added the column as Ecto's default
    # :string, which PostgreSQL renders as varchar(255). The decline path
    # (`MeetingQueries.transition_from_awaiting_approval/2`) writes via
    # `Repo.update_all`, bypassing the changeset's `validate_length/3`
    # entirely, so a 256-500 character reason raises a Postgrex error at the
    # database instead of being rejected — or accepted — by the changeset.
    # Widening varchar -> text is a catalogue-only change in PostgreSQL: no
    # table rewrite, no scan, only a brief metadata lock. This mirrors
    # 20260725055344's widening of meetings.provider_event_id.
    alter table(:meetings) do
      # excellent_migrations:safety-assured-for-next-line column_type_changed
      modify(:decline_reason, :text, from: :string)
    end
  end
end
