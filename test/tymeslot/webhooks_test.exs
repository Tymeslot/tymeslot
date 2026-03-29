defmodule Tymeslot.WebhooksTest do
  use Tymeslot.DataCase, async: false

  @moduletag :security

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Webhooks

  setup do
    setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
    :ok
  end

  # ============================================================================
  # SSRF Protection (existing tests)
  # ============================================================================

  describe "test_webhook_connection/2 - SSRF protection" do
    setup do
      setup_config(:tymeslot, :environment, :prod)
      :ok
    end

    test "blocks requests to private IP addresses in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://192.168.1.1/webhook")
      assert message =~ "private"
    end

    test "blocks requests to localhost in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://localhost/webhook")
      assert message =~ "private"
    end

    test "blocks HTTP URLs in production" do
      assert {:error, message} =
               Webhooks.test_webhook_connection("http://example.com/webhook")

      assert message =~ "HTTPS"
    end

    test "blocks requests to loopback address in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://127.0.0.1/webhook")
      assert message =~ "private"
    end
  end

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  describe "create_webhook/2" do
    test "creates a webhook with valid attributes" do
      user = insert(:user)

      attrs = %{
        name: "My Webhook",
        url: "https://example.com/webhook",
        events: ["meeting.created"]
      }

      assert {:ok, webhook} = Webhooks.create_webhook(user.id, attrs)
      assert webhook.name == "My Webhook"
      assert webhook.url == "https://example.com/webhook"
      assert webhook.events == ["meeting.created"]
      assert webhook.user_id == user.id
      assert webhook.is_active == true
    end

    test "generates a webhook token automatically" do
      user = insert(:user)

      attrs = %{
        name: "Token Test",
        url: "https://example.com/hook",
        events: ["meeting.created"]
      }

      assert {:ok, webhook} = Webhooks.create_webhook(user.id, attrs)
      assert webhook.webhook_token_encrypted != nil
    end

    test "returns error changeset when name is missing" do
      user = insert(:user)
      attrs = %{url: "https://example.com/hook", events: ["meeting.created"]}

      assert {:error, changeset} = Webhooks.create_webhook(user.id, attrs)
      assert %{name: [_error | _rest]} = errors_on(changeset)
    end

    test "returns error changeset when url is missing" do
      user = insert(:user)
      attrs = %{name: "Missing URL", events: ["meeting.created"]}

      assert {:error, changeset} = Webhooks.create_webhook(user.id, attrs)
      assert %{url: [_error | _rest]} = errors_on(changeset)
    end

    test "returns error changeset with invalid event types" do
      user = insert(:user)

      attrs = %{
        name: "Bad Events",
        url: "https://example.com/hook",
        events: ["invalid.event"]
      }

      assert {:error, changeset} = Webhooks.create_webhook(user.id, attrs)
      assert %{events: [_msg | _rest]} = errors_on(changeset)
    end

    test "allows creation with empty events list (default)" do
      user = insert(:user)

      attrs = %{
        name: "No Events",
        url: "https://example.com/hook",
        events: []
      }

      # Empty list matches the schema default, so no change is detected
      # and the events validation is not triggered
      assert {:ok, webhook} = Webhooks.create_webhook(user.id, attrs)
      assert webhook.events == []
    end
  end

  describe "list_webhooks/1" do
    test "returns webhooks belonging to the user" do
      user = insert(:user)
      webhook = insert(:webhook, user: user)

      result = Webhooks.list_webhooks(user.id)

      assert length(result) == 1
      assert hd(result).id == webhook.id
    end

    test "does not return webhooks belonging to other users" do
      user = insert(:user)
      other_user = insert(:user)
      insert(:webhook, user: other_user)

      result = Webhooks.list_webhooks(user.id)

      assert result == []
    end

    test "returns empty list when user has no webhooks" do
      user = insert(:user)

      assert Webhooks.list_webhooks(user.id) == []
    end

    test "decrypts webhook tokens in returned results" do
      user = insert(:user)

      {:ok, _webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Token Check",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      [listed] = Webhooks.list_webhooks(user.id)
      assert listed.webhook_token != nil
      assert is_binary(listed.webhook_token)
    end
  end

  describe "get_webhook/2" do
    test "returns the webhook when it belongs to the user" do
      user = insert(:user)

      {:ok, created} =
        Webhooks.create_webhook(user.id, %{
          name: "Findable",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      assert {:ok, found} = Webhooks.get_webhook(created.id, user.id)
      assert found.id == created.id
    end

    test "returns error when webhook does not exist" do
      user = insert(:user)

      assert {:error, :not_found} = Webhooks.get_webhook(-1, user.id)
    end

    test "returns error when webhook belongs to a different user" do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, created} =
        Webhooks.create_webhook(other_user.id, %{
          name: "Other User's Webhook",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      assert {:error, :not_found} = Webhooks.get_webhook(created.id, user.id)
    end

    test "decrypts the webhook token" do
      user = insert(:user)

      {:ok, created} =
        Webhooks.create_webhook(user.id, %{
          name: "Decrypt Check",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      assert {:ok, found} = Webhooks.get_webhook(created.id, user.id)
      assert found.webhook_token != nil
      assert is_binary(found.webhook_token)
    end
  end

  describe "update_webhook/2" do
    test "updates webhook attributes" do
      user = insert(:user)

      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Original",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      assert {:ok, updated} = Webhooks.update_webhook(webhook, %{name: "Updated"})
      assert updated.name == "Updated"
      assert updated.url == "https://example.com/hook"
    end

    test "updates the URL" do
      user = insert(:user)

      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "URL Update",
          url: "https://example.com/old",
          events: ["meeting.created"]
        })

      assert {:ok, updated} =
               Webhooks.update_webhook(webhook, %{url: "https://example.com/new"})

      assert updated.url == "https://example.com/new"
    end

    test "updates events list" do
      user = insert(:user)

      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Events Update",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      assert {:ok, updated} =
               Webhooks.update_webhook(webhook, %{
                 events: ["meeting.created", "meeting.cancelled"]
               })

      assert "meeting.cancelled" in updated.events
    end

    test "returns error with invalid events" do
      user = insert(:user)

      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Bad Update",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      assert {:error, changeset} =
               Webhooks.update_webhook(webhook, %{events: ["not.real"]})

      assert %{events: [_msg | _rest]} = errors_on(changeset)
    end
  end

  describe "toggle_webhook/1" do
    test "toggles active webhook to inactive" do
      user = insert(:user)

      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Toggle Test",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      assert webhook.is_active == true
      assert {:ok, toggled} = Webhooks.toggle_webhook(webhook)
      assert toggled.is_active == false
    end

    test "toggles inactive webhook back to active" do
      user = insert(:user)

      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Toggle Back",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      {:ok, inactive} = Webhooks.toggle_webhook(webhook)
      assert inactive.is_active == false

      {:ok, active_again} = Webhooks.toggle_webhook(inactive)
      assert active_again.is_active == true
    end
  end

  describe "delete_webhook/1" do
    test "deletes the webhook" do
      user = insert(:user)

      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "To Delete",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      assert {:ok, _webhook} = Webhooks.delete_webhook(webhook)
      assert {:error, :not_found} = Webhooks.get_webhook(webhook.id, user.id)
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  describe "validate_webhook_url/1" do
    test "accepts valid HTTPS URL" do
      assert :ok = Webhooks.validate_webhook_url("https://example.com/webhook")
    end

    test "accepts HTTP URL in non-production" do
      assert :ok = Webhooks.validate_webhook_url("http://example.com/webhook")
    end

    test "accepts localhost in non-production" do
      assert :ok = Webhooks.validate_webhook_url("http://localhost:4000/webhook")
    end

    test "rejects URL without protocol" do
      assert {:error, _reason} = Webhooks.validate_webhook_url("example.com/webhook")
    end

    test "rejects HTTP URL in production" do
      setup_config(:tymeslot, :environment, :prod)

      assert {:error, message} = Webhooks.validate_webhook_url("http://example.com/webhook")
      assert message =~ "HTTPS"
    end

    test "rejects private URLs in production" do
      setup_config(:tymeslot, :environment, :prod)

      assert {:error, message} = Webhooks.validate_webhook_url("https://192.168.1.1/webhook")
      assert message =~ "private"
    end
  end

  # ============================================================================
  # Token Regeneration
  # ============================================================================

  describe "regenerate_token/1" do
    test "generates a new token different from the original" do
      user = insert(:user)

      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Regen Test",
          url: "https://example.com/hook",
          events: ["meeting.created"]
        })

      original_encrypted = webhook.webhook_token_encrypted

      assert {:ok, regenerated} = Webhooks.regenerate_token(webhook)
      assert regenerated.webhook_token_encrypted != original_encrypted
    end
  end

  # ============================================================================
  # Events
  # ============================================================================

  describe "available_events/0" do
    test "returns a non-empty list" do
      events = Webhooks.available_events()
      assert events != []
    end

    test "contains meeting.created event" do
      events = Webhooks.available_events()
      values = Enum.map(events, & &1.value)
      assert "meeting.created" in values
    end

    test "contains meeting.cancelled event" do
      events = Webhooks.available_events()
      values = Enum.map(events, & &1.value)
      assert "meeting.cancelled" in values
    end

    test "contains meeting.rescheduled event" do
      events = Webhooks.available_events()
      values = Enum.map(events, & &1.value)
      assert "meeting.rescheduled" in values
    end

    test "each event has value, label, and description keys" do
      events = Webhooks.available_events()

      Enum.each(events, fn event ->
        assert Map.has_key?(event, :value)
        assert Map.has_key?(event, :label)
        assert Map.has_key?(event, :description)
      end)
    end
  end

  # ============================================================================
  # Headers
  # ============================================================================

  describe "build_headers/2" do
    test "includes content type and user agent" do
      headers = Webhooks.build_headers(%{}, nil)

      assert {"Content-Type", "application/json"} in headers
      assert {"User-Agent", "Tymeslot-Webhooks/1.0"} in headers
    end

    test "includes timestamp header" do
      headers = Webhooks.build_headers(%{}, nil)
      assert Enum.any?(headers, fn {k, _v} -> k == "X-Tymeslot-Timestamp" end)
    end

    test "includes token header when token is provided" do
      headers = Webhooks.build_headers(%{}, "my-secret-token")
      assert {"X-Tymeslot-Token", "my-secret-token"} in headers
    end

    test "omits token header when token is nil" do
      headers = Webhooks.build_headers(%{}, nil)
      refute Enum.any?(headers, fn {k, _v} -> k == "X-Tymeslot-Token" end)
    end
  end
end
