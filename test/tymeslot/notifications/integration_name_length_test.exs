defmodule Tymeslot.Notifications.IntegrationNameLengthTest do
  @moduledoc """
  Every notification channel holds an integration's name to the same range,
  `Constraints.integration_name_length_range/0`, in its schema and in the
  form validation in front of it.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :notifications

  import Tymeslot.Factory

  alias Tymeslot.Slack.InputValidation, as: SlackInput
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram.InputValidation, as: TelegramInput
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Webhooks.InputValidation, as: WebhookInput
  alias Tymeslot.Webhooks.WebhookSchema

  @longest String.duplicate("n", 100)
  @too_long String.duplicate("n", 101)

  describe "schemas" do
    test "Slack accepts 100 characters and refuses 101" do
      integration = insert(:slack_integration)

      assert SlackIntegrationSchema.user_changeset(integration, %{name: @longest}).valid?
      refute SlackIntegrationSchema.user_changeset(integration, %{name: @too_long}).valid?
    end

    test "Telegram accepts 100 characters and refuses 101" do
      integration = insert(:telegram_integration)

      assert TelegramIntegrationSchema.user_changeset(integration, %{name: @longest}).valid?
      refute TelegramIntegrationSchema.user_changeset(integration, %{name: @too_long}).valid?
    end

    test "webhooks accept 100 characters and refuse 101" do
      webhook = insert(:webhook)

      assert WebhookSchema.update_changeset(webhook, %{name: @longest}).valid?
      refute WebhookSchema.update_changeset(webhook, %{name: @too_long}).valid?
    end
  end

  describe "form validation" do
    test "Slack refuses a 101-character name" do
      params = %{
        "name" => @too_long,
        "events" => ["meeting.created"],
        "webhook_url" => "https://hooks.slack.com/services/T1/B2/abc123"
      }

      assert {:error, %{name: _message}} = SlackInput.validate_form(params, mode: :webhook_url)

      assert {:ok, %{name: @longest}} =
               SlackInput.validate_form(%{params | "name" => @longest}, mode: :webhook_url)
    end

    test "Telegram refuses a 101-character name" do
      params = %{"name" => @too_long, "events" => ["meeting.created"]}

      assert {:error, %{name: _message}} = TelegramInput.validate_form(params, bot_mode: "shared")

      assert {:ok, %{name: @longest}} =
               TelegramInput.validate_form(%{params | "name" => @longest}, bot_mode: "shared")
    end

    test "webhooks refuse a 101-character name" do
      assert {:error, %{name: _message}} =
               WebhookInput.validate_webhook_form(%{
                 "name" => @too_long,
                 "url" => "https://example.com/hook",
                 "events" => ["meeting.created"]
               })
    end

    test "an over-long name already stored passes unchanged, and only unchanged" do
      stored = String.duplicate("s", 120)

      slack = %{
        "name" => stored,
        "events" => ["meeting.cancelled"],
        "webhook_url" => "https://hooks.slack.com/services/T1/B2/abc123"
      }

      assert {:ok, %{name: ^stored}} =
               SlackInput.validate_form(slack, mode: :webhook_url, stored_name: stored)

      assert {:error, %{name: _message}} =
               SlackInput.validate_form(%{slack | "name" => stored <> "x"},
                 mode: :webhook_url,
                 stored_name: stored
               )

      telegram = %{"name" => stored, "events" => ["meeting.cancelled"]}

      assert {:ok, %{name: ^stored}} =
               TelegramInput.validate_form(telegram, bot_mode: "shared", stored_name: stored)

      assert {:error, %{name: _message}} =
               TelegramInput.validate_form(%{telegram | "name" => stored <> "x"},
                 bot_mode: "shared",
                 stored_name: stored
               )

      webhook = %{
        "name" => stored,
        "url" => "https://example.com/hook",
        "events" => ["meeting.cancelled"]
      }

      assert {:ok, %{name: ^stored}} =
               WebhookInput.validate_webhook_form(webhook, stored_name: stored)

      assert {:error, %{name: _message}} =
               WebhookInput.validate_webhook_form(%{webhook | "name" => stored <> "x"},
                 stored_name: stored
               )
    end
  end
end
