defmodule Tymeslot.Repo.Migrations.DropMarketingUnsubscribedAtFromUsers do
  use Ecto.Migration

  @moduledoc """
  Retires the SaaS-only `users.marketing_unsubscribed_at` column. The opt-out
  state now lives in the SaaS-owned `marketing_unsubscriptions` table.

  Order-independent by design. On deploy, Core migrates before SaaS
  (`start.sh`), so on a combined upgrade this can run before the SaaS
  create/backfill migration. To avoid losing data in that case, this migration
  preserves any opt-outs itself before dropping the column:

    * If there is opt-out data to keep, it ensures the target table exists
      (`CREATE TABLE IF NOT EXISTS`, matching the SaaS schema so the SaaS
      migration's `create_if_not_exists` no-ops when it runs afterwards) and
      copies the rows across (ON CONFLICT DO NOTHING — idempotent).
    * On a Core-only install there is never any opt-out data (Core has no
      marketing sender), so the guard is false and no SaaS table is created —
      the column is simply dropped.

  The raw SQL references the table by name only; it introduces no compile-time
  dependency on SaaS.

  DEPLOY ORDER DEPENDENCY: this migration must only ship in a release whose
  code no longer maps `marketing_unsubscribed_at` on `Tymeslot.Auth.UserSchema`
  (i.e. one that already includes the marketing opt-out separation). Deploying
  it against code that still selects the column will break every user query.
  """

  def up do
    execute(
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'users' AND column_name = 'marketing_unsubscribed_at'
        )
        AND EXISTS (SELECT 1 FROM users WHERE marketing_unsubscribed_at IS NOT NULL) THEN
          CREATE TABLE IF NOT EXISTS marketing_unsubscriptions (
            id bigserial PRIMARY KEY,
            user_id bigint NOT NULL,
            unsubscribed_at timestamp(0) NOT NULL,
            inserted_at timestamp(0) NOT NULL,
            updated_at timestamp(0) NOT NULL
          );

          CREATE UNIQUE INDEX IF NOT EXISTS marketing_unsubscriptions_user_id_index
            ON marketing_unsubscriptions (user_id);

          INSERT INTO marketing_unsubscriptions (user_id, unsubscribed_at, inserted_at, updated_at)
          SELECT id, marketing_unsubscribed_at, NOW(), NOW()
          FROM users
          WHERE marketing_unsubscribed_at IS NOT NULL
          ON CONFLICT (user_id) DO NOTHING;
        END IF;
      END $$;
      """,
      ""
    )

    alter table(:users) do
      remove_if_exists(:marketing_unsubscribed_at, :utc_datetime)
    end
  end

  def down do
    # Lossy by design. This re-adds the column empty — it does not copy the
    # opt-out timestamps back from marketing_unsubscriptions, and on a combined
    # rollback the SaaS migration has already dropped that table anyway (SaaS
    # unwinds first). Rolling back therefore leaves every user with a null
    # opt-out, effectively re-subscribing them. Snapshot the data first if the
    # consent state must survive a rollback.
    alter table(:users) do
      add_if_not_exists(:marketing_unsubscribed_at, :utc_datetime)
    end
  end
end
