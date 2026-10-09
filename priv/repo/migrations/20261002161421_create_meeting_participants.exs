defmodule Tymeslot.Repo.Migrations.CreateMeetingParticipants do
  @moduledoc """
  Creates `meeting_participants`: one row per person holding a seat on a
  group meeting.

  A seat is released by setting `cancelled_at`, never by deleting the row, so
  a cancelled seat stays visible to the organiser and returns to the pool.

  Each participant manages their seat through a link carrying a management
  token. The token is shown again after it is issued (every email to the
  participant rebuilds their links), so it is stored encrypted in
  `management_token_encrypted`, and looked up by its SHA-256 in
  `management_token_hash`, as RSVP tokens are. There is no plain column.

  `ical_sequence` is the seat's own calendar-file revision, since each seat is
  its own event in the participant's calendar. `confirmation_sent_at` and
  `organizer_notified_at` record which notifications of a booking have gone
  out, so a retried booking does not send them twice.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  #
  # The reference and every index are on the table created in this same
  # migration. It is empty and unreachable until the migration commits, so
  # there are no rows to validate and no concurrent readers to lock out.

  def change do
    create table(:meeting_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :meeting_id,
          references(:meetings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :email, :string, null: false
      add :phone, :string
      add :company, :string
      add :message, :text
      add :timezone, :string, null: false
      add :locale, :string, default: "en", null: false
      add :custom_field_answers, :map, default: %{}, null: false
      add :management_token_encrypted, :binary
      add :management_token_hash, :string
      add :ical_sequence, :integer, default: 0, null: false
      add :confirmation_sent_at, :utc_datetime
      add :organizer_notified_at, :utc_datetime
      add :cancelled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:meeting_participants, [:meeting_id])
    create unique_index(:meeting_participants, [:management_token_hash])

    # One live seat per address per slot. Without it, submitting the booking
    # form from two tabs consumes two seats and issues two management tokens,
    # so cancelling "the" booking frees only half of what was taken.
    create unique_index(:meeting_participants, ["meeting_id", "lower(email)"],
             where: "cancelled_at IS NULL",
             name: :meeting_participants_live_email_index
           )
  end
end
