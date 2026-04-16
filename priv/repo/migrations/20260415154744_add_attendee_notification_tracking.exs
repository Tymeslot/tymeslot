defmodule Tymeslot.Repo.Migrations.AddAttendeeNotificationTracking do
  use Ecto.Migration

  def up do
    alter table(:meetings) do
      add(:ical_sequence, :integer, null: false, default: 0)
      add(:last_notified_state, :map, null: false, default: %{})
    end

    alter table(:provider_calendar_events) do
      add(:ical_sequence, :integer, null: false, default: 0)
      add(:last_notified_state, :map, null: false, default: %{})

      add(
        :video_integration_id,
        references(:video_integrations, on_delete: :nilify_all, type: :id),
        null: true
      )
    end

    create(index(:provider_calendar_events, [:video_integration_id]))

    execute("""
    UPDATE meetings SET last_notified_state = jsonb_build_object(
      'title',       COALESCE(to_jsonb(title), 'null'::jsonb),
      'starts_at',   COALESCE(to_jsonb(start_time), 'null'::jsonb),
      'ends_at',     COALESCE(to_jsonb(end_time), 'null'::jsonb),
      'location',    COALESCE(to_jsonb(location), 'null'::jsonb),
      'description', COALESCE(to_jsonb(description), 'null'::jsonb),
      'video_link',  COALESCE(to_jsonb(attendee_video_url), 'null'::jsonb),
      'attendees',   CASE
                       WHEN attendee_email IS NULL THEN '[]'::jsonb
                       ELSE jsonb_build_array(attendee_email)
                     END
    )
    """)

    execute("""
    UPDATE provider_calendar_events SET last_notified_state = jsonb_build_object(
      'title',       COALESCE(to_jsonb(summary),     'null'::jsonb),
      'starts_at',   COALESCE(to_jsonb(start_at),    'null'::jsonb),
      'ends_at',     COALESCE(to_jsonb(end_at),      'null'::jsonb),
      'location',    COALESCE(to_jsonb(location),    'null'::jsonb),
      'description', COALESCE(to_jsonb(description), 'null'::jsonb),
      'video_link',  'null'::jsonb,
      'attendees',   COALESCE(to_jsonb(attendees),   '[]'::jsonb)
    )
    """)
  end

  def down do
    alter table(:provider_calendar_events) do
      remove(:video_integration_id)
      remove(:last_notified_state)
      remove(:ical_sequence)
    end

    alter table(:meetings) do
      remove(:last_notified_state)
      remove(:ical_sequence)
    end
  end
end
