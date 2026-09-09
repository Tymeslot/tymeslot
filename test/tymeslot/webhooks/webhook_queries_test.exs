defmodule Tymeslot.Webhooks.WebhookQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :automation
  @moduletag :queries
  @moduletag :security

  import Tymeslot.Factory

  alias Tymeslot.Webhooks.WebhookQueries

  # Parity with the Slack, Telegram and notification query tests, each of which
  # already pins its own cross-user contract. `get_webhook/2` is safe by
  # construction — the user is in the `Repo.get_by` — but it sits next to an
  # unscoped `get_webhook/1` reserved for trusted internal callers, and an
  # asymmetric family is where the next reader assumes a guarantee that is not
  # actually asserted anywhere.

  describe "get_webhook/2" do
    test "returns the webhook when the id and user match" do
      webhook = insert(:webhook)

      assert {:ok, found} = WebhookQueries.get_webhook(webhook.id, webhook.user_id)
      assert found.id == webhook.id
    end

    test "returns not_found for another user's webhook" do
      webhook = insert(:webhook)
      other_user = insert(:user)

      assert {:error, :not_found} = WebhookQueries.get_webhook(webhook.id, other_user.id)
    end

    test "returns not_found for an id that does not exist" do
      user = insert(:user)

      assert {:error, :not_found} = WebhookQueries.get_webhook(-1, user.id)
    end
  end

  describe "get_webhook/1" do
    test "is deliberately unscoped, so callers must own the authorization" do
      webhook = insert(:webhook)

      # Pinned so the difference between the two arities stays visible: this one
      # answers "does this row exist", never "may this user see it". A caller
      # reaching for it with a client-supplied id is the bug this documents.
      assert {:ok, found} = WebhookQueries.get_webhook(webhook.id)
      assert found.id == webhook.id
    end
  end

  describe "list_webhooks/1" do
    test "returns only the given user's webhooks" do
      user = insert(:user)
      mine = insert(:webhook, user: user)
      _theirs = insert(:webhook)

      assert [found] = WebhookQueries.list_webhooks(user.id)
      assert found.id == mine.id
    end
  end

  describe "list_active_webhooks_for_event/2" do
    test "never returns another user's webhook for the same event" do
      user = insert(:user)
      mine = insert(:webhook, user: user, is_active: true, events: ["meeting.created"])
      _theirs = insert(:webhook, is_active: true, events: ["meeting.created"])

      assert [found] = WebhookQueries.list_active_webhooks_for_event(user.id, "meeting.created")
      assert found.id == mine.id
    end
  end
end
