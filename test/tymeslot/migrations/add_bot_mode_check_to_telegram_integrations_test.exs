defmodule Tymeslot.Migrations.AddBotModeCheckToTelegramIntegrationsTest do
  @moduledoc """
  Verifies `20261029130530_add_bot_mode_check_to_telegram_integrations`
  repairs an out-of-vocabulary `bot_mode` from the row's own data (a stored
  bot token means `own`, none means `shared`), leaves known values alone, and
  then closes the column with a CHECK constraint.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :telegram
  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_130_530

  test "repairs an unknown bot mode from the stored token and re-closes the constraint" do
    with_token = insert(:telegram_integration, bot_mode: :own)
    without_token = insert(:telegram_integration, bot_mode: :shared, bot_token_encrypted: nil)
    shared = insert(:telegram_integration, bot_mode: :shared, bot_token_encrypted: nil)

    MigrationRunner.down!(@version)
    set_raw_bot_mode!(with_token.id, "personal")
    set_raw_bot_mode!(without_token.id, "personal")

    MigrationRunner.up!(@version)

    assert %{bot_mode: :own} = Repo.reload!(with_token)
    assert %{bot_mode: :shared} = Repo.reload!(without_token)
    assert %{bot_mode: :shared} = Repo.reload!(shared)

    assert_raise Postgrex.Error, ~r/telegram_integrations_bot_mode_must_be_known/, fn ->
      set_raw_bot_mode!(shared.id, "personal")
    end
  end

  defp set_raw_bot_mode!(id, bot_mode) do
    Repo.query!("UPDATE telegram_integrations SET bot_mode = $1 WHERE id = $2", [bot_mode, id])
  end
end
