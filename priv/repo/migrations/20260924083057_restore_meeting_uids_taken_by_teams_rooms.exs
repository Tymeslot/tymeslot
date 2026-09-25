defmodule Tymeslot.Repo.Migrations.RestoreMeetingUidsTakenByTeamsRooms do
  @moduledoc """
  Gives back the booking's own `uid` to meetings whose Microsoft Teams room
  took it over, so the cancel and reschedule links already sent for them work
  again.

  Until this release, attaching a Teams room to a booking wrote the Graph id of
  the room's calendar event into `meetings.uid`. The uid is the booking's
  public identifier: the cancel, reschedule and calendar download links are
  built from it at booking time, stored in `cancel_url` and `reschedule_url`,
  and emailed to the attendee. Every one of those links then pointed at a uid
  no meeting carried, and opening one landed on the login page with "Meeting
  not found". New bookings no longer overwrite it; this repairs the ones that
  did.

  ## Which rows

  Meetings with a Teams room (by `video_provider`, or by the join link on rows
  from before that column), whose uid is not a UUID, and whose stored cancel or
  reschedule link still carries the UUID the booking was created with. That
  UUID becomes the uid again, unless another meeting already holds it or
  claims it too.

  The overwritten value was the calendar event the booking's own calendar sync
  had been writing to whenever it ran after the room was attached, since sync
  targets the uid when there is no `provider_event_id`. Such a row keeps that
  event by moving the value to `provider_event_id`, which sync prefers; a row
  that already has one keeps it.

  Rolling back is a no-op: restoring broken links would reintroduce the defect.
  """

  use Ecto.Migration

  def up do
    # A bounded one-shot repair of rows only a previous release could write;
    # an `UPDATE` recovering a value from another column by pattern has no
    # migration DSL form.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    WITH recovered AS (
      SELECT id,
             uid AS overwritten_uid,
             COALESCE(
               substring(cancel_url FROM '/meeting/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})/cancel'),
               substring(reschedule_url FROM '/meeting/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})/reschedule')
             ) AS original_uid
      FROM meetings
      WHERE uid !~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
        AND (video_provider = 'teams'
             OR meeting_url LIKE '%teams.microsoft.com/%'
             OR meeting_url LIKE '%teams.live.com/%')
    )
    UPDATE meetings AS m
    SET uid = r.original_uid,
        provider_event_id = COALESCE(NULLIF(m.provider_event_id, ''), r.overwritten_uid),
        updated_at = NOW()
    FROM recovered AS r
    WHERE m.id = r.id
      AND r.original_uid IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM meetings AS other WHERE other.uid = r.original_uid)
      AND NOT EXISTS (
        SELECT 1 FROM recovered AS twin
        WHERE twin.original_uid = r.original_uid AND twin.id <> r.id
      )
    """)
  end

  def down, do: :ok
end
