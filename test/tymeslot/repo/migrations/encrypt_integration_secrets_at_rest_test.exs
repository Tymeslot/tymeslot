defmodule Tymeslot.Repo.Migrations.EncryptIntegrationSecretsAtRestTest do
  @moduledoc """
  Webhook URLs, custom meeting links and the push notification secrets were
  stored in plain text. The migration encrypts each into its `*_encrypted`
  column and keeps the plain value, which the previous release still reads if
  the image is rolled back; it also replaces the custom link's account key,
  which was the link itself, with its hash.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :security
  @moduletag :migrations

  alias Tymeslot.Integrations.Video.AccountKey
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_002_051_404

  test "encrypts each secret and keeps the plain value for a rollback" do
    webhook = insert(:webhook, url: "https://hooks.example.com/a")

    calendar =
      insert(:calendar_integration,
        google_channel_secret: "channel-secret",
        graph_client_state: "client-state"
      )

    video =
      insert(:video_integration,
        provider: "custom",
        custom_meeting_url: "https://zoom.us/j/1?pwd=one"
      )

    # Rolling back writes each value into its plain column, as the previous
    # release kept it, so going up again meets rows as that release left them.
    MigrationRunner.rerun!(@version)

    for {table, id, column, value} <- [
          {"webhooks", webhook.id, "url", "https://hooks.example.com/a"},
          {"calendar_integrations", calendar.id, "google_channel_secret", "channel-secret"},
          {"calendar_integrations", calendar.id, "graph_client_state", "client-state"},
          {"video_integrations", video.id, "custom_meeting_url", "https://zoom.us/j/1?pwd=one"}
        ] do
      assert {^value, ciphertext} = stored(table, id, column)
      assert Encryption.decrypt(ciphertext) == value
    end
  end

  test "keys a custom link on the hash of its key, and leaves other providers alone" do
    custom =
      insert(:video_integration,
        provider: "custom",
        custom_meeting_url: "https://zoom.us/j/1?pwd=one",
        provider_account_id: "https://zoom.us/j/1?pwd=one"
      )

    jitsi =
      insert(:video_integration,
        provider: "jitsi",
        base_url: "https://meet.example.com",
        provider_account_id: "https://meet.example.com"
      )

    MigrationRunner.rerun!(@version)

    assert key(custom) == AccountKey.key_for(:custom, "https://zoom.us/j/1?pwd=one")
    assert key(jitsi) == "https://meet.example.com"
  end

  test "rolling back restores each plain column from its encrypted value, over a stale copy" do
    webhook = insert(:webhook, url: "https://hooks.example.com/current")
    unreadable = insert(:webhook, url: "https://hooks.example.com/unreadable")

    video =
      insert(:video_integration,
        provider: "custom",
        custom_meeting_url: "https://zoom.us/j/1?pwd=current"
      )

    # Plain copies left behind by something other than the application, which
    # empties them on every change: the encrypted value is the current one.
    for {table, id, column} <- [
          {"webhooks", webhook.id, "url"},
          {"webhooks", unreadable.id, "url"},
          {"video_integrations", video.id, "custom_meeting_url"}
        ] do
      Repo.query!("UPDATE #{table} SET #{column} = 'stale' WHERE id = $1", [id])
    end

    Repo.query!("UPDATE webhooks SET url_encrypted = $1 WHERE id = $2", [
      "not ciphertext",
      unreadable.id
    ])

    MigrationRunner.down!(@version)

    assert plain("webhooks", webhook.id, "url") == "https://hooks.example.com/current"

    assert plain("video_integrations", video.id, "custom_meeting_url") ==
             "https://zoom.us/j/1?pwd=current"

    # A value no key opens is skipped rather than written as garbage.
    assert plain("webhooks", unreadable.id, "url") == "stale"
  end

  defp plain(table, id, column) do
    %{rows: [[value]]} = Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [id])
    value
  end

  defp stored(table, id, column) do
    %{rows: [[plain, ciphertext]]} =
      Repo.query!("SELECT #{column}, #{column}_encrypted FROM #{table} WHERE id = $1", [id])

    {plain, ciphertext}
  end

  defp key(row) do
    %{rows: [[key]]} =
      Repo.query!("SELECT provider_account_id FROM video_integrations WHERE id = $1", [row.id])

    key
  end
end
