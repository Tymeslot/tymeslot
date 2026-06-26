defmodule Tymeslot.Repo.Migrations.AddFreebusyTokenToProfiles do
  use Ecto.Migration

  # Nullable secret token for the public free/busy feed (GET /free-busy/:token).
  # NULL means the feed is disabled for that profile. Unique so a token maps to
  # exactly one profile.
  def change do
    alter table(:profiles) do
      add :freebusy_token, :string
    end

    # The column is brand-new and nullable; every existing row is NULL and
    # Postgres permits unlimited NULLs under a unique index, so no
    # data-preparation step is needed. `create_if_not_exists` keeps the
    # migration idempotent for partially-applied states.
    create_if_not_exists unique_index(:profiles, [:freebusy_token])
  end
end
