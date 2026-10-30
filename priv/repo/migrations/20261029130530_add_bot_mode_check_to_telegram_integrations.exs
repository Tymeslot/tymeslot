defmodule Tymeslot.Repo.Migrations.AddBotModeCheckToTelegramIntegrations do
  use Ecto.Migration

  @moduledoc """
  Closes the `telegram_integrations.bot_mode` vocabulary at the database
  layer, matching the `Ecto.Enum` the schema now declares. `Ecto.Enum` raises
  on load for a value outside its list, so a stray row would break every read
  of it.

  A row outside `shared | own` is repaired from what it holds rather than
  from the installation's setting, which a migration cannot read reliably and
  which says nothing about how an existing row was made. Only an own-bot
  integration ever stores a bot token: the form requires one on create, and
  on the shared bot the token field is never cast. So a row with a token
  becomes `own`, and a row without one becomes `shared`, the only mode it
  can deliver in. Before the repair such a row could not deliver at all,
  since resolving its bot token matched neither mode.
  """

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so the ACCESS EXCLUSIVE lock the constraint
  # takes to validate existing rows blocks no live traffic. Revisit this if a
  # deployment target ever migrates against a running instance. The raw UPDATE
  # is the backfill that constraint needs: it has no changeset to run through,
  # and it must repair the rows before the constraint can accept them.
  def up do
    execute("""
    UPDATE telegram_integrations
    SET bot_mode = CASE WHEN bot_token_encrypted IS NULL THEN 'shared' ELSE 'own' END
    WHERE bot_mode NOT IN ('shared', 'own')
    """)

    create(
      constraint(:telegram_integrations, :telegram_integrations_bot_mode_must_be_known,
        check: "bot_mode IN ('shared', 'own')"
      )
    )
  end

  def down do
    drop(constraint(:telegram_integrations, :telegram_integrations_bot_mode_must_be_known))
  end
end
