defmodule Tymeslot.Repo.Migrations.RepairCustomFieldMinMaxStrings do
  use Ecto.Migration

  @moduledoc """
  Repairs custom-field definitions whose `min`/`max` bounds were persisted as
  JSON numbers under an earlier schema (when `FieldDefinition.min`/`max` were
  `:integer`). They are now `:string`, so a stored number such as `1` makes
  `Ecto.Embedded.load/3` raise `cannot load 1 as type :string` and crashes any
  query that touches the row.

  Casts numeric `min`/`max` to their text representation in-place, preserving
  array order. Idempotent: only rows that still hold a numeric bound are
  rewritten, so re-running (or running on a clean database) is a no-op. The
  conversion is one-way, so `down` does nothing.
  """

  def up do
    repair("meeting_types", "custom_fields")
    repair("meetings", "custom_fields_snapshot")
  end

  def down, do: :ok

  # Rewrites a `jsonb[]` column, stringifying any numeric `min`/`max` on each
  # element. The WHERE EXISTS guard limits writes to affected rows; the
  # ORDINALITY/ORDER BY pair keeps element order stable.
  defp repair(table, column) do
    execute("""
    UPDATE #{table} AS t
    SET #{column} = (
      SELECT array_agg(
        elem
          || CASE WHEN jsonb_typeof(elem->'min') = 'number'
                  THEN jsonb_build_object('min', to_jsonb(elem->>'min'))
                  ELSE '{}'::jsonb END
          || CASE WHEN jsonb_typeof(elem->'max') = 'number'
                  THEN jsonb_build_object('max', to_jsonb(elem->>'max'))
                  ELSE '{}'::jsonb END
        ORDER BY ord
      )
      FROM unnest(t.#{column}) WITH ORDINALITY AS u(elem, ord)
    )
    WHERE EXISTS (
      SELECT 1 FROM unnest(t.#{column}) AS u(elem)
      WHERE jsonb_typeof(elem->'min') = 'number'
         OR jsonb_typeof(elem->'max') = 'number'
    )
    """)
  end
end
