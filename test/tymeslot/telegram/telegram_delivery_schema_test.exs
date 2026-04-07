defmodule Tymeslot.Telegram.TelegramDeliverySchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :schema
  @moduletag :telegram

  import Ecto.Changeset

  alias Ecto.UUID
  alias Tymeslot.Telegram.TelegramDeliverySchema

  @valid_attrs %{
    integration_id: 1,
    event_type: "meeting.created"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = TelegramDeliverySchema.changeset(%TelegramDeliverySchema{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = TelegramDeliverySchema.changeset(%TelegramDeliverySchema{}, %{})
      refute changeset.valid?

      assert %{
               integration_id: ["can't be blank"],
               event_type: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "applies default attempt_count" do
      changeset = TelegramDeliverySchema.changeset(%TelegramDeliverySchema{}, @valid_attrs)
      assert get_field(changeset, :attempt_count) == 1
    end

    test "accepts optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          meeting_id: UUID.generate(),
          message_text: "New meeting scheduled",
          response_status: 200,
          response_body: ~s({"ok":true}),
          error_message: nil,
          delivered_at: DateTime.utc_now(:second),
          attempt_count: 3
        })

      changeset = TelegramDeliverySchema.changeset(%TelegramDeliverySchema{}, attrs)
      assert changeset.valid?
    end
  end

  describe "successful?/1" do
    test "returns true for 2xx status codes" do
      assert TelegramDeliverySchema.successful?(%TelegramDeliverySchema{response_status: 200})
      assert TelegramDeliverySchema.successful?(%TelegramDeliverySchema{response_status: 201})
      assert TelegramDeliverySchema.successful?(%TelegramDeliverySchema{response_status: 299})
    end

    test "returns false for non-2xx status codes" do
      refute TelegramDeliverySchema.successful?(%TelegramDeliverySchema{response_status: 199})
      refute TelegramDeliverySchema.successful?(%TelegramDeliverySchema{response_status: 300})
      refute TelegramDeliverySchema.successful?(%TelegramDeliverySchema{response_status: 400})
      refute TelegramDeliverySchema.successful?(%TelegramDeliverySchema{response_status: 500})
    end

    test "returns false for nil status" do
      refute TelegramDeliverySchema.successful?(%TelegramDeliverySchema{response_status: nil})
    end
  end
end
