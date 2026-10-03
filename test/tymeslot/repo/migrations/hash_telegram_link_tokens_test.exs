defmodule Tymeslot.Repo.Migrations.HashTelegramLinkTokensTest do
  @moduledoc """
  Telegram link tokens were stored as themselves. The migration backfills
  each outstanding token's hash, which the bot's lookup now uses, and keeps
  the plain token, which the previous release still looks up if the image is
  rolled back.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :telegram
  @moduletag :migrations

  alias Tymeslot.Telegram
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_002_052_430

  test "a link the previous release handed out still links the chat" do
    integration =
      insert(:telegram_integration,
        bot_mode: "shared",
        chat_id: nil,
        link_token_issued_at: DateTime.utc_now(:second)
      )

    Repo.query!("UPDATE telegram_integrations SET link_token = $1 WHERE id = $2", [
      "old-link-token",
      integration.id
    ])

    MigrationRunner.rerun!(@version)

    assert {:ok, %{id: id}} = Telegram.handle_start_payload("old-link-token", "123456")
    assert id == integration.id

    %{rows: [[plain]]} =
      Repo.query!("SELECT link_token FROM telegram_integrations WHERE id = $1", [integration.id])

    assert plain == "old-link-token"
  end
end
