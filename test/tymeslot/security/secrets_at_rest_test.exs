defmodule Tymeslot.Security.SecretsAtRestTest do
  @moduledoc """
  The secrets and capability tokens kept outside the credential tables reach
  the database encrypted or hashed, never as the value itself: a leaked
  backup, a SQL console or a replica must not hand over a working webhook,
  meeting passcode or link.

  Each test writes a known value through the schema and reads the raw row
  back with SQL, below the schema's own decoding.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :security
  @moduletag :schema

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Token
  alias Tymeslot.Telegram
  alias Tymeslot.Webhooks.WebhookSchema

  describe "encrypted secrets" do
    test "a webhook URL" do
      url = "https://hooks.zapier.com/hooks/catch/123/secret-path"
      webhook = insert(:webhook, url: url)

      assert_encrypted("webhooks", webhook.id, "url", url)
      assert Repo.get!(WebhookSchema, webhook.id).url == url
    end

    test "a custom meeting link" do
      url = "https://zoom.us/j/123456?pwd=passcode"
      integration = insert(:video_integration, provider: "custom", custom_meeting_url: url)

      assert_encrypted("video_integrations", integration.id, "custom_meeting_url", url)
      assert Repo.get!(VideoIntegrationSchema, integration.id).custom_meeting_url == url
    end

    test "a Google push channel secret" do
      integration = insert(:calendar_integration, google_channel_secret: "channel-secret")

      assert_encrypted(
        "calendar_integrations",
        integration.id,
        "google_channel_secret",
        "channel-secret"
      )

      assert Repo.get!(CalendarIntegrationSchema, integration.id).google_channel_secret ==
               "channel-secret"
    end

    test "an Outlook subscription client state" do
      integration = insert(:calendar_integration, graph_client_state: "client-state")

      assert_encrypted(
        "calendar_integrations",
        integration.id,
        "graph_client_state",
        "client-state"
      )

      assert Repo.get!(CalendarIntegrationSchema, integration.id).graph_client_state ==
               "client-state"
    end
  end

  describe "hashed tokens" do
    test "a Telegram link token, cleared once it links a chat" do
      integration = insert(:telegram_integration, bot_mode: "shared", chat_id: nil)
      {:ok, token} = Telegram.refresh_link_token(integration)

      assert_hashed("telegram_integrations", integration.id, "link_token", token)

      assert {:ok, _linked} = Telegram.handle_start_payload(token, "123456")
      assert raw("telegram_integrations", integration.id, "link_token_hash") == nil
    end
  end

  # The plain column the value used to live in stays empty, and the encrypted
  # one opens to the value without containing it.
  defp assert_encrypted(table, id, column, value) do
    %{rows: [[plain, ciphertext]]} =
      Repo.query!("SELECT #{column}, #{column}_encrypted FROM #{table} WHERE id = $1", [id])

    assert plain == nil
    refute ciphertext =~ value
    assert Encryption.decrypt(ciphertext) == value
  end

  # The plain column stays empty, and the hash column holds the token's hash.
  defp assert_hashed(table, id, column, token) do
    assert is_binary(token)
    assert raw(table, id, column) == nil
    assert raw(table, id, "#{column}_hash") == Token.hash_token(token)
  end

  defp raw(table, id, column) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [dump_id(id)])

    value
  end

  # Postgrex takes a UUID as its 16 raw bytes.
  defp dump_id(id) when is_integer(id), do: id
  defp dump_id(id), do: Ecto.UUID.dump!(id)
end
