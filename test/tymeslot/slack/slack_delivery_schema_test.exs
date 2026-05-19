defmodule Tymeslot.Slack.SlackDeliverySchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :schema
  @moduletag :slack

  import Tymeslot.Factory

  alias Tymeslot.Slack.SlackDeliverySchema

  describe "changeset/2" do
    test "requires integration_id and event_type" do
      cs = SlackDeliverySchema.changeset(%SlackDeliverySchema{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:integration_id]
      assert errors[:event_type]
    end

    test "accepts a complete payload" do
      integration = insert(:slack_integration)

      attrs = %{
        integration_id: integration.id,
        event_type: "meeting.created",
        meeting_id: "abc",
        message_blocks: %{"blocks" => []},
        response_status: 200,
        response_body: ~s({"ok":true}),
        delivered_at: DateTime.utc_now(),
        attempt_count: 1
      }

      cs = SlackDeliverySchema.changeset(%SlackDeliverySchema{}, attrs)
      assert cs.valid?
    end
  end

  describe "successful?/1" do
    test "true when response_status is 2xx and error_message is nil" do
      assert SlackDeliverySchema.successful?(%SlackDeliverySchema{response_status: 200})
      refute SlackDeliverySchema.successful?(%SlackDeliverySchema{response_status: 500})

      refute SlackDeliverySchema.successful?(%SlackDeliverySchema{
               response_status: 200,
               error_message: "channel_not_found"
             })
    end
  end
end
