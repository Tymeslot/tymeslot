defmodule Tymeslot.Repo.Migrations.CreateMeetings do
  use Ecto.Migration

  def change do
    create table(:meetings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :uid, :string, null: false
      add :title, :string, null: false
      add :summary, :string
      add :description, :text
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime, null: false
      add :duration, :integer
      add :location, :string
      add :meeting_type, :string

      # Organizer details
      add :organizer_name, :string, null: false
      add :organizer_email, :string, null: false
      add :organizer_title, :string

      # Attendee details
      add :attendee_name, :string, null: false
      add :attendee_email, :string, null: false
      add :attendee_message, :text
      add :attendee_phone, :string
      add :attendee_company, :string

      # URLs and links
      add :view_url, :string
      add :reschedule_url, :string
      add :cancel_url, :string
      add :meeting_url, :string

      # Calendar integration
      add :google_calendar_url, :string
      add :outlook_calendar_url, :string
      add :ics_download_url, :string

      # Reminder settings
      add :reminder_time, :string
      add :default_reminder_time, :string

      # Status tracking
      add :status, :string, default: "pending", null: false

      # Email tracking
      add :organizer_email_sent, :boolean, default: false, null: false
      add :attendee_email_sent, :boolean, default: false, null: false
      add :reminder_email_sent, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:meetings, [:uid])
    create index(:meetings, [:start_time])
    create index(:meetings, [:end_time])
    create index(:meetings, [:status])
    create index(:meetings, [:organizer_email])
    create index(:meetings, [:attendee_email])
  end
end
