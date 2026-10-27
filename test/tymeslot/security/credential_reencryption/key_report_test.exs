defmodule Tymeslot.Security.CredentialReencryption.KeyReportTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LegacyCiphertext
  alias Tymeslot.Workers.EmailWorker

  test "counts each column's values by the key version that opens them" do
    insert(:telegram_integration, bot_token_encrypted: LegacyCiphertext.encrypt("legacy"))
    insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("current"))
    insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("current too"))
    insert(:telegram_integration, bot_token_encrypted: :crypto.strong_rand_bytes(40))

    report = CredentialReencryption.key_report()

    assert report.tables["telegram_integrations"][:bot_token_encrypted] ==
             %{0 => 1, Encryption.current_version() => 2, unreadable: 1}
  end

  test "leaves empty columns out and lists every covered column" do
    insert(:telegram_integration, bot_token_encrypted: nil)

    report = CredentialReencryption.key_report()

    assert report.tables["telegram_integrations"][:bot_token_encrypted] == %{}

    for {table, columns} <- CredentialReencryption.covered_tables(), column <- columns do
      assert Map.has_key?(report.tables[table], column), "#{table}.#{column} is not reported"
    end
  end

  test "totals add up across tables and columns, paging through every row" do
    insert_list(3, :telegram_integration, bot_token_encrypted: LegacyCiphertext.encrypt("x"))
    insert(:slack_integration, bot_token_encrypted: LegacyCiphertext.encrypt("y"))

    report = CredentialReencryption.key_report(batch_size: 1)

    column_sum =
      for {_table, columns} <- report.tables, {_column, counts} <- columns, reduce: 0 do
        acc -> acc + Map.get(counts, 0, 0)
      end

    assert report.tables["telegram_integrations"][:bot_token_encrypted][0] == 3
    assert report.tables["slack_integrations"][:bot_token_encrypted][0] == 1
    assert report.totals[0] == column_sum
  end

  test "counts the links held by email jobs not yet done, not those already sent" do
    pending = insert_link_job("https://app.example.com/reset/pending")
    sent = insert_link_job("https://app.example.com/reset/sent")
    Repo.update_all(from(j in Oban.Job, where: j.id == ^sent.id), set: [state: "completed"])

    report = CredentialReencryption.key_report()

    assert report.tables["oban_jobs"] == %{email_links: %{Encryption.current_version() => 1}}
    assert pending.state == "available"
  end

  defp insert_link_job(url) do
    %{"action" => "send_password_reset", "user_id" => 1}
    |> LinkArg.put("reset_url", url)
    |> EmailWorker.new()
    |> Oban.insert!()
  end
end
