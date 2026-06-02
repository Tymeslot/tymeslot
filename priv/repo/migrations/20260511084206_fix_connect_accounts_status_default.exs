defmodule Tymeslot.Repo.Migrations.FixConnectAccountsStatusDefault do
  @moduledoc """
  Corrects the DB-level default for `connect_accounts.status` from `"active"`
  to `"creating"`.

  A freshly-inserted row should be in the `"creating"` placeholder state until
  the Stripe account creation call succeeds. The original migration accidentally
  set `"active"` as the default. Only the explicit `status: "creating"` in
  `ConnectAccountQueries.insert_placeholder/2` prevented silent corruption.

  This migration changes the column default so any future insert path that omits
  `status` gets the correct safe default.

  No existing rows need backfilling — any row currently in `"active"` was either
  legitimately promoted to that status or is an already-wrong placeholder that
  the application already handles.
  """

  use Ecto.Migration

  def up do
    # Defensive data-preparation step — the column is already `null: false`
    # in the original migration, but the self-healing pattern guards against
    # any rows that might have slipped through in unusual deploy states.
    execute("UPDATE connect_accounts SET status = 'creating' WHERE status IS NULL")

    alter table(:connect_accounts) do
      modify(:status, :string,
        default: "creating",
        null: false,
        from: {:string, default: "active", null: false}
      )
    end
  end

  def down do
    alter table(:connect_accounts) do
      modify(:status, :string,
        default: "active",
        null: false,
        from: {:string, default: "creating", null: false}
      )
    end
  end
end
