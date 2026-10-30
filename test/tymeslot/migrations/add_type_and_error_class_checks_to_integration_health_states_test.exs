defmodule Tymeslot.Migrations.AddTypeAndErrorClassChecksToIntegrationHealthStatesTest do
  @moduledoc """
  Verifies `20261029125806_add_type_and_error_class_checks_to_integration_health_states`
  deletes rows of an unknown `integration_type`, backfills an unknown
  `last_error_class` to `hard`, leaves known values and NULL alone, and then
  closes both columns with CHECK constraints.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_125_806

  test "repairs unknown types and error classes, then re-closes both constraints" do
    user = insert(:user)

    [stray_type, stray_class] =
      health_rows!(user, :calendar, insert_pair(:calendar_integration, user: user))

    [transient, clean] = health_rows!(user, :video, insert_pair(:video_integration, user: user))

    IntegrationHealthStateQueries.update_fields(:video, transient.integration_id,
      last_error_class: :transient
    )

    MigrationRunner.down!(@version)
    set_raw!(stray_type.id, "integration_type", "zoom")
    set_raw!(stray_class.id, "last_error_class", "fatal")

    MigrationRunner.up!(@version)

    refute Repo.get(IntegrationHealthStateSchema, stray_type.id)
    assert %{last_error_class: :hard} = Repo.reload!(stray_class)
    assert %{last_error_class: :transient} = Repo.reload!(transient)
    assert %{integration_type: :video, last_error_class: nil} = Repo.reload!(clean)

    assert_raise Postgrex.Error,
                 ~r/integration_health_states_integration_type_must_be_known/,
                 fn -> set_raw!(clean.id, "integration_type", "zoom") end

    assert_raise Postgrex.Error,
                 ~r/integration_health_states_last_error_class_must_be_known/,
                 fn -> set_raw!(clean.id, "last_error_class", "fatal") end
  end

  defp health_rows!(user, kind, integrations) do
    Enum.map(integrations, fn integration ->
      {:ok, row} = IntegrationHealthStateQueries.get_or_init(kind, integration.id, user.id)
      row
    end)
  end

  defp set_raw!(id, column, value) do
    Repo.query!("UPDATE integration_health_states SET #{column} = $1 WHERE id = $2", [value, id])
  end
end
