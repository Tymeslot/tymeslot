defmodule Tymeslot.Repo.Migrations.FixCalendarPathsArrayFormat do
  use Ecto.Migration

  def up do
    # Fix calendar_paths that were incorrectly saved as comma-separated strings
    # within a single array element instead of separate array elements
    execute("""
    UPDATE calendar_integrations
    SET calendar_paths = string_to_array(calendar_paths[1], ',')
    WHERE
      array_length(calendar_paths, 1) = 1
      AND calendar_paths[1] LIKE '%,%'
      AND provider IN ('caldav', 'radicale', 'nextcloud')
    """)
  end

  def down do
    # No-op: we can't reliably reverse this transformation
    # as we don't know which paths were originally comma-separated strings
  end
end
