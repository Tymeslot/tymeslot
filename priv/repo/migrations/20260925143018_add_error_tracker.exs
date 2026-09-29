defmodule Tymeslot.Repo.Migrations.AddErrorTracker do
  use Ecto.Migration

  # Pinned to the latest schema version ErrorTracker 0.9 ships. A later
  # ErrorTracker release that adds a version gets its own migration, as with
  # Oban's, so an installed database never changes shape under a released one.
  def up, do: ErrorTracker.Migration.up(version: 5)
  def down, do: ErrorTracker.Migration.down(version: 1)
end
