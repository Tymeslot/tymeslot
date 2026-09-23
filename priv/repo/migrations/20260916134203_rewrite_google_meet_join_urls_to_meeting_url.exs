defmodule Tymeslot.Repo.Migrations.RewriteGoogleMeetJoinUrlsToMeetingUrl do
  @moduledoc """
  Replaces the per-participant Google Meet links stored on existing meetings
  with the plain meeting link, so every surface that re-reads them hands out
  the link that works.

  Until this release, booking a meeting with a Google Meet room stored a
  different link for each role: the meeting URL with that person's email
  address, name and a host flag appended as query parameters
  (`?authuser=<email>&uname=<name>&role=host`). Meet ignores the name and the
  host flag, and `authuser` only selects a signed-in Google account, so a
  participant not signed in under exactly that address landed on a sign-in
  page or an account chooser instead of the room. The link also carried their
  email address, readable by anyone it was forwarded to. The provider now
  hands every role the plain meeting URL.

  That fixes new bookings only. Both links are written once, at booking time,
  into `organizer_video_url` and `attendee_video_url`, and read back from
  there by reschedule emails, the calendar file export, the agenda, the
  calendar grid and webhook payloads, so a meeting booked before the fix
  keeps serving the broken links for as long as it exists. This overwrites
  both columns with `meeting_url`, which is what the provider stores today.

  ## Which rows

  Meetings whose room is a Google Meet one (`video_provider = 'google_meet'`),
  that have a meeting URL to fall back on, and where either stored link
  differs from it. It is deliberately not bounded to upcoming meetings: the
  calendar export and webhook payloads re-read past meetings too. Rows
  already carrying the plain link, rows of other providers (whose per-role
  links are genuine, distinct join URLs), and Meet rows with no meeting URL
  are left as they are.

  Rolling back is a no-op. The old links were built from participant data
  the provider no longer appends, and rebuilding them would reintroduce the
  defect this repairs.
  """

  use Ecto.Migration

  def up do
    # A bounded one-shot repair of rows only a previous release could write;
    # an `UPDATE` with a predicate on a text column has no migration DSL form.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meetings
    SET organizer_video_url = meeting_url,
        attendee_video_url = meeting_url,
        updated_at = NOW()
    WHERE video_provider = 'google_meet'
      AND meeting_url IS NOT NULL
      AND meeting_url <> ''
      AND (organizer_video_url IS DISTINCT FROM meeting_url
           OR attendee_video_url IS DISTINCT FROM meeting_url)
    """)
  end

  def down, do: :ok
end
