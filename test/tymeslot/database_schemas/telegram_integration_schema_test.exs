defmodule Tymeslot.DatabaseSchemas.TelegramIntegrationSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :schema
  @moduletag :telegram

  import Ecto.Changeset
  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.TelegramIntegrationSchema

  describe "changeset/2" do
    test "valid with required fields" do
      user = insert(:user)

      attrs = %{
        name: "My Telegram Bot",
        user_id: user.id,
        bot_mode: "own"
      }

      changeset = TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{})
      refute changeset.valid?

      assert %{
               name: ["can't be blank"],
               user_id: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates name minimum length" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{
          name: "",
          user_id: user.id,
          bot_mode: "own"
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "validates name maximum length" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{
          name: String.duplicate("a", 256),
          user_id: user.id,
          bot_mode: "own"
        })

      refute changeset.valid?
      assert "should be at most 255 character(s)" in errors_on(changeset).name
    end

    test "validates bot_mode inclusion" do
      user = insert(:user)

      for mode <- ["shared", "own"] do
        changeset =
          TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{
            name: "Bot",
            user_id: user.id,
            bot_mode: mode
          })

        assert changeset.valid?, "expected bot_mode #{inspect(mode)} to be valid"
      end
    end

    test "rejects invalid bot_mode" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{
          name: "Bot",
          user_id: user.id,
          bot_mode: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).bot_mode
    end

    test "validates events with valid event types" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own",
          events: ["meeting.created", "meeting.cancelled"]
        })

      assert changeset.valid?
    end

    test "rejects invalid event types" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own",
          events: ["meeting.created", "invalid.event"]
        })

      refute changeset.valid?
      assert "contains invalid events: invalid.event" in errors_on(changeset).events
    end

    test "applies default values" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own"
        })

      assert get_field(changeset, :events) == []
      assert get_field(changeset, :is_active) == true
      assert get_field(changeset, :failure_count) == 0
    end
  end

  describe "derive_status/1" do
    test "returns :pending_link when chat_id is nil" do
      integration = %TelegramIntegrationSchema{chat_id: nil, is_active: true}
      assert TelegramIntegrationSchema.derive_status(integration).status == :pending_link
    end

    test "returns :active when linked and active" do
      integration = %TelegramIntegrationSchema{
        chat_id: "123",
        is_active: true,
        disabled_at: nil
      }

      assert TelegramIntegrationSchema.derive_status(integration).status == :active
    end

    test "returns :paused when inactive without disabled_at" do
      integration = %TelegramIntegrationSchema{
        chat_id: "123",
        is_active: false,
        disabled_at: nil
      }

      assert TelegramIntegrationSchema.derive_status(integration).status == :paused
    end

    test "returns :auto_disabled when inactive with disabled_at" do
      integration = %TelegramIntegrationSchema{
        chat_id: "123",
        is_active: false,
        disabled_at: DateTime.utc_now()
      }

      assert TelegramIntegrationSchema.derive_status(integration).status == :auto_disabled
    end
  end

  describe "subscribed_to?/2" do
    test "returns true when event is in the events list" do
      integration = %TelegramIntegrationSchema{events: ["meeting.created", "meeting.cancelled"]}
      assert TelegramIntegrationSchema.subscribed_to?(integration, "meeting.created")
    end

    test "returns false when event is not in the events list" do
      integration = %TelegramIntegrationSchema{events: ["meeting.created"]}
      refute TelegramIntegrationSchema.subscribed_to?(integration, "meeting.cancelled")
    end

    test "returns false when events list is empty" do
      integration = %TelegramIntegrationSchema{events: []}
      refute TelegramIntegrationSchema.subscribed_to?(integration, "meeting.created")
    end
  end

  describe "should_be_active?/1" do
    test "returns true for active integration with chat_id and no issues" do
      integration = %TelegramIntegrationSchema{
        is_active: true,
        chat_id: "123",
        disabled_at: nil,
        failure_count: 0
      }

      assert TelegramIntegrationSchema.should_be_active?(integration)
    end

    test "returns false when is_active is false" do
      integration = %TelegramIntegrationSchema{
        is_active: false,
        chat_id: "123",
        disabled_at: nil,
        failure_count: 0
      }

      refute TelegramIntegrationSchema.should_be_active?(integration)
    end

    test "returns false when chat_id is nil" do
      integration = %TelegramIntegrationSchema{
        is_active: true,
        chat_id: nil,
        disabled_at: nil,
        failure_count: 0
      }

      refute TelegramIntegrationSchema.should_be_active?(integration)
    end

    test "returns false when disabled_at is set" do
      integration = %TelegramIntegrationSchema{
        is_active: true,
        chat_id: "123",
        disabled_at: DateTime.utc_now(),
        failure_count: 0
      }

      refute TelegramIntegrationSchema.should_be_active?(integration)
    end

    test "returns false when failure_count reaches max" do
      integration = %TelegramIntegrationSchema{
        is_active: true,
        chat_id: "123",
        disabled_at: nil,
        failure_count: TelegramIntegrationSchema.max_failure_count()
      }

      refute TelegramIntegrationSchema.should_be_active?(integration)
    end

    test "returns true when failure_count is below max" do
      integration = %TelegramIntegrationSchema{
        is_active: true,
        chat_id: "123",
        disabled_at: nil,
        failure_count: TelegramIntegrationSchema.max_failure_count() - 1
      }

      assert TelegramIntegrationSchema.should_be_active?(integration)
    end
  end

  describe "valid_events/0" do
    test "returns the list of valid event types" do
      events = TelegramIntegrationSchema.valid_events()
      assert "meeting.created" in events
      assert "meeting.cancelled" in events
      assert "meeting.rescheduled" in events
      assert length(events) >= 3
    end
  end
end
