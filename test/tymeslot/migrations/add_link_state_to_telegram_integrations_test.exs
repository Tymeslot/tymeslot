defmodule Tymeslot.Migrations.AddLinkStateToTelegramIntegrationsTest do
  @moduledoc """
  Value-correctness regression for
  `20260917131412_add_link_state_to_telegram_integrations`.

  The backfill decides which existing rows count as linked. A linked
  integration left unstamped reads as an abandoned setup stub once it is
  disconnected, and is deleted with its delivery log; a stub stamped by
  mistake is never cleaned up. The migration is driven from `priv` through
  `MigrationRunner.rerun!/1`, which drops both columns and adds them back, so
  every row meets the backfill with nothing stamped.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :telegram
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_917_131_412

  @updated_at ~U[2026-08-01 10:00:00Z]

  describe "linked_at" do
    test "stamps an integration with a chat with its updated_at" do
      integration = integration(chat_id: "123")

      MigrationRunner.rerun!(@version)

      assert column(integration, "linked_at") == @updated_at
    end

    test "stamps a disconnected integration that has delivered a message" do
      integration = integration(chat_id: nil, last_triggered_at: ~U[2026-07-01 09:00:00Z])

      MigrationRunner.rerun!(@version)

      assert column(integration, "linked_at") == @updated_at
    end

    test "stamps a disconnected integration that has a delivery log" do
      integration = integration(chat_id: nil)
      insert(:telegram_delivery, integration: integration)

      MigrationRunner.rerun!(@version)

      assert column(integration, "linked_at") == @updated_at
    end

    test "leaves a setup stub that was never linked unstamped" do
      stub = integration(chat_id: nil)

      MigrationRunner.rerun!(@version)

      assert is_nil(column(stub, "linked_at"))
    end
  end

  describe "link_token_issued_at" do
    test "stamps an outstanding token with the row's updated_at" do
      stub = integration(chat_id: nil, link_token: "outstanding-token")

      MigrationRunner.rerun!(@version)

      assert column(stub, "link_token_issued_at") == @updated_at
    end

    test "leaves a row without a token unstamped" do
      integration = integration(chat_id: "123")

      MigrationRunner.rerun!(@version)

      assert is_nil(column(integration, "link_token_issued_at"))
    end
  end

  defp integration(attrs) do
    insert(
      :telegram_integration,
      Keyword.merge([bot_mode: "shared", updated_at: @updated_at], attrs)
    )
  end

  defp column(%{id: id}, name) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{name} FROM telegram_integrations WHERE id = $1", [id])

    value && DateTime.from_naive!(value, "Etc/UTC")
  end
end
