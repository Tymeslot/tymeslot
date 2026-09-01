defmodule Tymeslot.Repo.Migrations.WidenWebhooksUrl do
  use Ecto.Migration

  def up do
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

  # `def change` would let Ecto derive the down migration by swapping
  # `modify/3`'s arguments, rewriting the column back to varchar(255) and
  # aborting with "value too long for type character varying(255)" against
  # any webhook URL saved longer than that, which is exactly the state this
  # migration exists to permit. Narrowing text -> varchar loses data rather
  # than merely changing storage, so this migration is intentionally one-way.
  def down do
    raise Ecto.MigrationError,
          "irreversible migration: widening webhooks.url to text cannot be safely " <>
            "rolled back once a URL longer than 255 characters has been stored"
  end
end
