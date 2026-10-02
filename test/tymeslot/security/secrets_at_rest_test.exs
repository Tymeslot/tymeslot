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

  # The plain column the value used to live in stays empty, and the encrypted
  # one opens to the value without containing it.
  defp assert_encrypted(table, id, column, value) do
    %{rows: [[plain, ciphertext]]} =
      Repo.query!("SELECT #{column}, #{column}_encrypted FROM #{table} WHERE id = $1", [id])

    assert plain == nil
    refute ciphertext =~ value
    assert Encryption.decrypt(ciphertext) == value
  end
end
