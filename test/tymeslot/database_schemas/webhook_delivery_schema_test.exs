defmodule Tymeslot.DatabaseSchemas.WebhookDeliverySchemaTest do
  @moduletag :utils
  use Tymeslot.DataCase, async: true
  alias Tymeslot.DatabaseSchemas.WebhookDeliverySchema

  describe "changeset/2" do
  @moduletag :utils
    test "valid with required fields" do
      attrs = %{
        webhook_id: 1,
        event_type: "meeting.created",
        payload: %{"id" => "123"}
      }

      changeset = WebhookDeliverySchema.changeset(%WebhookDeliverySchema{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = WebhookDeliverySchema.changeset(%WebhookDeliverySchema{}, %{})
      refute changeset.valid?

      assert %{
               webhook_id: ["can't be blank"],
               event_type: ["can't be blank"],
               payload: ["can't be blank"]
             } = errors_on(changeset)
    end
  end

  describe "successful?/1" do
    test "returns true for 2xx status" do
      assert WebhookDeliverySchema.successful?(%WebhookDeliverySchema{response_status: 200})
      assert WebhookDeliverySchema.successful?(%WebhookDeliverySchema{response_status: 201})
      assert WebhookDeliverySchema.successful?(%WebhookDeliverySchema{response_status: 299})
    end

    test "returns false for other statuses" do
      refute WebhookDeliverySchema.successful?(%WebhookDeliverySchema{response_status: 300})
      refute WebhookDeliverySchema.successful?(%WebhookDeliverySchema{response_status: 400})
      refute WebhookDeliverySchema.successful?(%WebhookDeliverySchema{response_status: 500})
      refute WebhookDeliverySchema.successful?(%WebhookDeliverySchema{response_status: nil})
    end
  end

  describe "retryable?/1" do
    test "returns true for 429, 5xx and nil" do
      assert WebhookDeliverySchema.retryable?(%WebhookDeliverySchema{response_status: 429})
      assert WebhookDeliverySchema.retryable?(%WebhookDeliverySchema{response_status: 500})
      assert WebhookDeliverySchema.retryable?(%WebhookDeliverySchema{response_status: 503})
      assert WebhookDeliverySchema.retryable?(%WebhookDeliverySchema{response_status: nil})
    end

    test "returns false for others" do
      refute WebhookDeliverySchema.retryable?(%WebhookDeliverySchema{response_status: 200})
      refute WebhookDeliverySchema.retryable?(%WebhookDeliverySchema{response_status: 400})
      refute WebhookDeliverySchema.retryable?(%WebhookDeliverySchema{response_status: 404})
    end
  end

  describe "status_message/1" do
    test "returns Success for successful delivery" do
      assert WebhookDeliverySchema.status_message(%WebhookDeliverySchema{response_status: 200}) ==
               "Success"
    end

    test "returns Error message if present" do
      assert WebhookDeliverySchema.status_message(%WebhookDeliverySchema{
               response_status: 400,
               error_message: "Failed"
             }) == "Error: Failed"
    end

    test "returns Rate limited for 429" do
      assert WebhookDeliverySchema.status_message(%WebhookDeliverySchema{response_status: 429}) ==
               "Rate limited"
    end

    test "returns Server error for 5xx" do
      assert WebhookDeliverySchema.status_message(%WebhookDeliverySchema{response_status: 500}) ==
               "Server error"
    end

    test "returns Client error for 4xx" do
      assert WebhookDeliverySchema.status_message(%WebhookDeliverySchema{response_status: 400}) ==
               "Client error"
    end

    test "returns Pending for others" do
      assert WebhookDeliverySchema.status_message(%WebhookDeliverySchema{response_status: 100}) ==
               "Pending"

      assert WebhookDeliverySchema.status_message(%WebhookDeliverySchema{response_status: nil}) ==
               "Pending"
    end
  end
end
