defmodule Tymeslot.WebhooksOwnershipTest do
  @moduledoc """
  The webhook context acts only on the acting user's own webhooks: every
  user-facing function answers `{:error, :not_found}` for someone else's.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :webhooks
  @moduletag :security

  import Tymeslot.Factory

  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.WebhookSchema

  describe "another user's webhook" do
    setup do
      owner = insert(:user)
      webhook = insert(:webhook, user: owner, name: "Owner's", is_active: true)
      insert(:webhook_delivery, webhook: webhook)
      %{webhook: webhook, intruder: insert(:user)}
    end

    test "cannot be read, changed or deleted, and is left as it was", %{
      webhook: webhook,
      intruder: intruder
    } do
      id = webhook.id
      user_id = intruder.id

      assert {:error, :not_found} = Webhooks.update_webhook(user_id, id, %{name: "Mine now"})
      assert {:error, :not_found} = Webhooks.toggle_webhook(user_id, id)
      assert {:error, :not_found} = Webhooks.regenerate_token(user_id, id)
      assert {:error, :not_found} = Webhooks.delivery_log(user_id, id)
      assert {:error, :not_found} = Webhooks.delete_webhook(user_id, id)

      unchanged = Repo.get!(WebhookSchema, id)
      assert unchanged.name == "Owner's"
      assert unchanged.is_active
      assert unchanged.webhook_token_encrypted == webhook.webhook_token_encrypted
    end

    test "is still the owner's to read", %{webhook: webhook} do
      assert {:ok, %{webhook: %{id: id}, deliveries: [_delivery], stats: %{total: 1}}} =
               Webhooks.delivery_log(webhook.user_id, webhook.id)

      assert id == webhook.id
    end
  end
end
