defmodule Tymeslot.Webhooks.WebhookDeliverySchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :utils

  alias Tymeslot.Webhooks.WebhookDeliverySchema

  describe "changeset/2" do
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
end
