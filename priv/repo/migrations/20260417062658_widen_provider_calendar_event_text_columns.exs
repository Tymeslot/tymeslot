defmodule Tymeslot.Repo.Migrations.WidenProviderCalendarEventTextColumns do
  @moduledoc """
  Converts free-form text columns on `provider_calendar_events` from the
  Ecto default `varchar(255)` to unbounded `text`.

  External calendar providers routinely emit values that exceed 255 bytes:
  long meeting titles (`summary`), addresses and joining-info blobs
  (`location`), complex `RRULE` strings, Google Meet / Zoom / Teams join
  URLs with signed tokens (`video_link`), and provider-specific identifiers
  (`provider_event_id`, `recurring_event_id`, iCalUID). When any of these
  exceeded 255 bytes, `INSERT` / `ON CONFLICT DO UPDATE` aborted with
  `22001 string_data_right_truncation`, dropping the entire batch for the
  affected integration.

  `text` and `varchar` share the same on-disk representation in PostgreSQL,
  so this is a metadata-only change with no table rewrite.
  """

  use Ecto.Migration

  @columns ~w(
    uid
    provider_calendar_id
    provider_event_id
    summary
    location
    recurrence_rule
    recurring_event_id
    etag
    video_link
  )

  def up do
    statements = Enum.map_join(@columns, ",\n  ", &"ALTER COLUMN #{&1} TYPE text")

    execute("ALTER TABLE provider_calendar_events\n  " <> statements)
  end

  def down do
    statements = Enum.map_join(@columns, ",\n  ", &"ALTER COLUMN #{&1} TYPE varchar(255)")

    execute("ALTER TABLE provider_calendar_events\n  " <> statements)
  end
end
