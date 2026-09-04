defmodule Tymeslot.Integrations.Calendar.ExchangeProviderConstraintMigrationTest do
  @moduledoc """
  Covers the migration that widens the calendar provider CHECK constraint to
  admit `exchange`.

  The rollback is the half worth pinning: it deletes Exchange integrations
  rather than re-homing them onto `caldav`, and a rollback that only narrowed
  the constraint would fail outright on any database holding one. The migration
  is driven from `priv` through `Ecto.Migrator` rather than from a pasted copy
  of its SQL; see `Tymeslot.Test.MigrationRunner`.

  Every test rolls the migration and applies it again first, and that is not
  ceremony: the test database is already fully migrated, so a test that only
  inserted a row would be asserting against the constraint the database happens
  to carry rather than the one this file installs. Take the `rerun!/1` out and
  the assertions below stay green against a migration that no longer admits
  `exchange` at all.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :calendar
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_819_170_102

  test "an exchange integration is admitted" do
    MigrationRunner.rerun!(@version)
    integration = insert(:calendar_integration)

    set_provider(integration.id, "exchange")

    assert provider_of(integration.id) == "exchange"
  end

  test "a provider nobody implements is still refused" do
    MigrationRunner.rerun!(@version)
    integration = insert(:calendar_integration)

    assert_raise Postgrex.Error, ~r/calendar_integrations_provider_check/, fn ->
      set_provider(integration.id, "lotus_notes")
    end
  end

  test "rolling back removes exchange integrations and leaves the rest alone" do
    exchange = insert(:calendar_integration)
    caldav = insert(:calendar_integration)
    set_provider(exchange.id, "exchange")

    MigrationRunner.down!(@version)

    refute integration_exists?(exchange.id)
    assert integration_exists?(caldav.id)
  end

  defp provider_of(id) do
    %{rows: [[provider]]} =
      Repo.query!("SELECT provider FROM calendar_integrations WHERE id = $1", [id])

    provider
  end

  defp set_provider(id, provider) do
    Repo.query!("UPDATE calendar_integrations SET provider = $1 WHERE id = $2", [provider, id])
  end

  defp integration_exists?(id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM calendar_integrations WHERE id = $1", [id])

    count == 1
  end
end
