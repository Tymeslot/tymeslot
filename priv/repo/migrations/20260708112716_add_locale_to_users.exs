defmodule Tymeslot.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  def change do
    # Nullable: NULL means "no explicit preference — follow the browser's
    # Accept-Language / session locale". A non-null value is the user's chosen
    # interface language and takes precedence. No backfill needed.
    alter table(:users) do
      add :locale, :string
    end
  end
end
