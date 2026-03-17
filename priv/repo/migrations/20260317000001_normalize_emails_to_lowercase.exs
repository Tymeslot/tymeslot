defmodule Tymeslot.Repo.Migrations.NormalizeEmailsToLowercase do
  use Ecto.Migration

  def up do
    # Normalize all existing email addresses to lowercase so that
    # case-insensitive lookup via String.downcase(input) works correctly.
    execute("UPDATE users SET email = LOWER(email) WHERE email != LOWER(email)")

    execute(
      "UPDATE users SET pending_email = LOWER(pending_email) WHERE pending_email IS NOT NULL AND pending_email != LOWER(pending_email)"
    )
  end

  def down do
    # Emails cannot be restored to their original casing; this migration is irreversible.
    :ok
  end
end
