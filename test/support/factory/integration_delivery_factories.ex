defmodule Tymeslot.Factory.IntegrationDeliveryFactories do
  @moduledoc """
  The webhook, Telegram and Slack factories, integrations and their
  deliveries, mixed into `Tymeslot.Factory` with `use`. Call them through
  `Tymeslot.Factory`: `insert(:webhook_delivery, webhook: webhook)`.
  """

  defmacro __using__(_opts) do
    quote do
      alias Tymeslot.Factory.TokenHash
      alias Tymeslot.Security.Encryption
      alias Tymeslot.Slack.SlackDeliverySchema
      alias Tymeslot.Slack.SlackIntegrationSchema
      alias Tymeslot.Telegram.TelegramDeliverySchema
      alias Tymeslot.Telegram.TelegramIntegrationSchema
      alias Tymeslot.Webhooks.WebhookDeliverySchema
      alias Tymeslot.Webhooks.WebhookSchema

      @spec webhook_factory() :: Tymeslot.Webhooks.WebhookSchema.t()
      def webhook_factory do
        %WebhookSchema{
          name: sequence(:webhook_name, &"Webhook #{&1}"),
          url: sequence(:webhook_url, &"https://example.com/webhook/#{&1}"),
          events: ["meeting.created", "meeting.cancelled"],
          is_active: true,
          webhook_token_encrypted: <<1, 2, 3>>,
          user: build(:user)
        }
      end

      # Takes the attrs so a `link_token` given to the factory is stored as the
      # hash the row is looked up by, as the changeset would store it.
      @spec telegram_integration_factory(map()) :: TelegramIntegrationSchema.t()
      def telegram_integration_factory(attrs) do
        %TelegramIntegrationSchema{
          name: sequence(:telegram_name, &"Telegram #{&1}"),
          bot_mode: :own,
          bot_token_encrypted:
            Encryption.encrypt("1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"),
          chat_id: sequence(:telegram_chat_id, &"#{&1 + 100_000}"),
          events: ["meeting.created", "meeting.cancelled"],
          is_active: true,
          user: build(:user)
        }
        |> merge_attributes(attrs)
        |> evaluate_lazy_attributes()
        |> TokenHash.put(:link_token, :link_token_hash)
      end

      @spec slack_integration_factory() :: SlackIntegrationSchema.t()
      def slack_integration_factory do
        %SlackIntegrationSchema{
          name: sequence(:slack_name, &"Slack #{&1}"),
          app_mode: :oauth,
          bot_token_encrypted: Encryption.encrypt("xoxb-test-token"),
          team_id: sequence(:slack_team_id, &"T#{&1 + 100_000}"),
          team_name: "Test Workspace",
          channel_id: sequence(:slack_channel_id, &"C#{&1 + 100_000}"),
          channel_name: "#bookings",
          events: ["meeting.created", "meeting.cancelled", "meeting.rescheduled"],
          is_active: true,
          user: build(:user)
        }
      end

      @spec telegram_delivery_factory() :: TelegramDeliverySchema.t()
      def telegram_delivery_factory do
        %TelegramDeliverySchema{
          integration: build(:telegram_integration),
          event_type: "meeting.created",
          message_text: "Test message",
          response_status: 200,
          attempt_count: 1,
          inserted_at: DateTime.utc_now()
        }
      end

      @spec slack_delivery_factory() :: SlackDeliverySchema.t()
      def slack_delivery_factory do
        %SlackDeliverySchema{
          integration: build(:slack_integration),
          event_type: "meeting.created",
          message_blocks: %{"blocks" => []},
          response_status: 200,
          attempt_count: 1,
          inserted_at: DateTime.utc_now()
        }
      end

      @spec webhook_delivery_factory() :: Tymeslot.Webhooks.WebhookDeliverySchema.t()
      def webhook_delivery_factory do
        %WebhookDeliverySchema{
          webhook: build(:webhook),
          event_type: "meeting.created",
          payload: %{"test" => true},
          response_status: 200,
          attempt_count: 1,
          inserted_at: DateTime.utc_now()
        }
      end
    end
  end
end
