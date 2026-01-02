defmodule Tymeslot.Repo.Migrations.RenameVerificationSentFromIpToSignupIp do
  use Ecto.Migration

  @disable_ddl_transaction true

  # NOTE: This migration is written with explicit up/down to ensure reversibility.
  # `remove/1` without a type is not reversible in Ecto.
  def up do
    alter table(:users) do
      add :signup_ip, :string
    end

    # Backfill while being safe if the column exists but is already populated.
    execute("""
    UPDATE users
    SET signup_ip = verification_sent_from_ip
    WHERE signup_ip IS NULL
      AND verification_sent_from_ip IS NOT NULL
    """)

    alter table(:users) do
      remove :verification_sent_from_ip
    end
  end

  def down do
    alter table(:users) do
      add :verification_sent_from_ip, :string
    end

    execute("""
    UPDATE users
    SET verification_sent_from_ip = signup_ip
    WHERE verification_sent_from_ip IS NULL
      AND signup_ip IS NOT NULL
    """)

    alter table(:users) do
      remove :signup_ip
    end
  end
end
