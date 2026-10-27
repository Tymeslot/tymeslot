defmodule Tymeslot.Webhooks.WebhookSchemaTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Security.Encryption
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Webhooks.WebhookSchema

  describe "generate_token/1" do
    test "generates a new token if one doesn't exist" do
      changeset =
        WebhookSchema.create_changeset(%{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          user_id: 1,
          events: ["meeting.created"]
        })

      assert token = get_change(changeset, :webhook_token)
      assert String.starts_with?(token, "ts_")
      assert get_change(changeset, :webhook_token_encrypted)
    end

    test "regenerates token when webhook_token is set to nil" do
      # Simulate an existing webhook
      webhook = %WebhookSchema{
        webhook_token_encrypted: Encryption.encrypt("old_token")
      }

      # Passing nil should trigger regeneration
      # We need to pass it in the attributes for the changeset to see it
      # Using string keys to simulate external input (e.g. from a form)
      changeset = WebhookSchema.update_changeset(webhook, %{"webhook_token" => nil})

      # The change should be present in the changeset
      # Note: We use get_field here because generate_token uses put_change.
      token = get_field(changeset, :webhook_token)
      assert is_binary(token), "Expected token to be a binary, got #{inspect(token)}"
      assert token != "old_token"
      assert String.starts_with?(token, "ts_")
      assert new_encrypted = get_change(changeset, :webhook_token_encrypted)
      assert Encryption.decrypt(new_encrypted) == token
    end

    test "does not regenerate token if it already exists and not changing" do
      encrypted = Encryption.encrypt("existing_token")

      webhook = %WebhookSchema{
        webhook_token_encrypted: encrypted
      }

      changeset = WebhookSchema.update_changeset(webhook, %{name: "Updated Name"})

      refute get_change(changeset, :webhook_token)
      assert get_field(changeset, :webhook_token_encrypted) == encrypted
    end
  end

  describe "create_changeset/1 - url column width" do
    test "a URL between 256 and the 2048 changeset limit passes validation and inserts" do
      # The changeset allows URLs up to Constraints.url_max_length/0 (2048),
      # so the database column must accept the same length or a URL between
      # 256 and 2048 characters passes the changeset here and then raises a
      # Postgrex error on insert.
      long_path = String.duplicate("a", 500)
      url = "https://example.com/" <> long_path
      assert String.length(url) > 255
      assert String.length(url) <= Constraints.url_max_length()

      user = insert(:user)

      changeset =
        WebhookSchema.create_changeset(%{
          name: "Long URL Webhook",
          url: url,
          user_id: user.id,
          events: ["meeting.created"]
        })

      assert changeset.valid?
      assert {:ok, webhook} = Repo.insert(changeset)
      assert webhook.url == url
    end
  end

  describe "update_changeset/2" do
    test "never reassigns the owner or writes delivery bookkeeping" do
      webhook = insert(:webhook)
      other = insert(:user)

      {:ok, updated} =
        webhook
        |> WebhookSchema.update_changeset(%{
          name: "Renamed",
          user_id: other.id,
          is_active: false,
          failure_count: 9,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "forged"
        })
        |> Repo.update()

      assert updated.name == "Renamed"
      assert updated.user_id == webhook.user_id
      assert updated.is_active
      assert updated.failure_count == webhook.failure_count
      assert is_nil(updated.disabled_at)
    end
  end
end
