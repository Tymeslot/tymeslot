defmodule Tymeslot.Repo.Migrations.RepairUnknownMeetingTypeLocationKinds do
  @moduledoc """
  A meeting type's location `kind` is now an `Ecto.Enum` inside the embedded
  `locations` list, and `Ecto.Enum` raises on load for a value outside its
  list. One stored location with an unknown kind would therefore break every
  read of its meeting type, taking the host's meeting settings and booking
  page down with it. A CHECK constraint cannot reach inside a `jsonb[]`
  column, so this migration repairs the stored data instead.

  Every location whose `kind` is present but not one of `video`, `in_person`,
  `phone` or `custom` becomes `custom`, the one kind with no requirements of
  its own: its label and free-text details stay, so the host still sees the
  option and the booker is still told what it is. The config that belongs to
  the other kinds (video providers, venues, asking the guest for a number) is
  cleared, as it is whenever a host changes an option's kind. A location with
  no kind is left alone, since `nil` loads without error. Rows without an
  unknown kind are untouched, so the migration is safe to run again.

  There is no `down`: the original values are not worth restoring, and the
  previous release reads `custom` as well as this one does.
  """
  use Ecto.Migration

  # Rewriting the stored lists is the whole of this migration; there is no
  # changeset to run them through.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update

  @known "'video', 'in_person', 'phone', 'custom'"

  def up do
    execute("""
    UPDATE meeting_types
    SET locations = (
      SELECT array_agg(
        CASE
          WHEN elem ? 'kind'
            AND jsonb_typeof(elem -> 'kind') <> 'null'
            AND elem ->> 'kind' NOT IN (#{@known})
          THEN elem || jsonb_build_object(
            'kind', 'custom',
            'video_integration_ids', '[]'::jsonb,
            'venue_ids', '[]'::jsonb,
            'collect_from_guest', false
          )
          ELSE elem
        END
        ORDER BY ord
      )
      FROM unnest(locations) WITH ORDINALITY AS entries(elem, ord)
    )
    WHERE EXISTS (
      SELECT 1 FROM unnest(locations) AS entry
      WHERE entry ? 'kind'
        AND jsonb_typeof(entry -> 'kind') <> 'null'
        AND entry ->> 'kind' NOT IN (#{@known})
    )
    """)
  end

  def down, do: :ok
end
