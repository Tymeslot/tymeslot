defmodule Tymeslot.Repo.Migrations.WidenWebhooksUrl do
  use Ecto.Migration

  def change do
    # The changeset allows URLs up to 2048 characters
    # (Tymeslot.Validation.Constraints.url_max_length/0), but the column is
    # still varchar(255), so anything longer passes the changeset and raises
    # a Postgrex error on insert. Widening varchar -> text is a
    # catalogue-only change in PostgreSQL: no table rewrite, no scan, only a
    # brief metadata lock.
    alter table(:webhooks) do
      # excellent_migrations:safety-assured-for-next-line column_type_changed
      modify(:url, :text, from: :string)
    end
  end
end
