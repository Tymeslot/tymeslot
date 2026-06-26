defmodule Tymeslot.Repo.Migrations.AddFreebusyTokenToProfiles do
  use Ecto.Migration

  # Nullable secret token for the public free/busy feed (GET /free-busy/:token).
  # NULL means the feed is disabled for that profile. Unique so a token maps to
  # exactly one profile.
  def change do
    alter table(:profiles) do
      add :freebusy_token, :string
    end

    create unique_index(:profiles, [:freebusy_token])
  end
end
