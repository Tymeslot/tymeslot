defmodule Tymeslot.Repo.Migrations.AddTypeAndErrorClassChecksToIntegrationHealthStates do
  use Ecto.Migration

  @moduledoc """
  Closes the `integration_health_states.integration_type` and
  `last_error_class` vocabularies at the database layer, matching the
  `Ecto.Enum`s the schema now declares. `Ecto.Enum` raises on load for a value
  outside its list, so a stray row would break every read of it.

  A row whose `integration_type` is neither `calendar` nor `video` is deleted.
  Every read and the orphan sweep select rows by one of the two known kinds,
  so such a row was already invisible: it drove no badge, probe or email, and
  nothing would ever clean it up. The table only tracks health, and the
  monitor seeds a fresh row for any active integration that lacks one, so
  deleting it loses nothing that can be read.

  An unknown `last_error_class` becomes `hard`. That is what the monitor
  already read it as, and what it wrote back on the row's next probe, so the
  repair only makes the stored value agree with the behaviour. NULL (no error
  recorded) stays valid.
  """

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so the ACCESS EXCLUSIVE lock the constraint
  # takes to validate existing rows blocks no live traffic. Revisit this if a
  # deployment target ever migrates against a running instance. The raw DELETE
  # and UPDATE are the backfill those constraints need: they have no changeset
  # to run through, and they must repair the rows before the constraints can
  # accept them.
  @known_types "'calendar', 'video'"
  @known_error_classes "'transient', 'hard'"

  def up do
    execute("""
    DELETE FROM integration_health_states
    WHERE integration_type NOT IN (#{@known_types})
    """)

    execute("""
    UPDATE integration_health_states
    SET last_error_class = 'hard'
    WHERE last_error_class IS NOT NULL
      AND last_error_class NOT IN (#{@known_error_classes})
    """)

    create(
      constraint(
        :integration_health_states,
        :integration_health_states_integration_type_must_be_known,
        check: "integration_type IN (#{@known_types})"
      )
    )

    create(
      constraint(
        :integration_health_states,
        :integration_health_states_last_error_class_must_be_known,
        check: "last_error_class IS NULL OR last_error_class IN (#{@known_error_classes})"
      )
    )
  end

  def down do
    drop(
      constraint(
        :integration_health_states,
        :integration_health_states_last_error_class_must_be_known
      )
    )

    drop(
      constraint(
        :integration_health_states,
        :integration_health_states_integration_type_must_be_known
      )
    )
  end
end
