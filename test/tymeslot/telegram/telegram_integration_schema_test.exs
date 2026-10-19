defmodule Tymeslot.Telegram.TelegramIntegrationSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :schema
  @moduletag :telegram

  import Ecto.Changeset
  import Tymeslot.Factory

  alias Tymeslot.Security.Encryption
  alias Tymeslot.Telegram.TelegramIntegrationSchema

  describe "create_changeset/1" do
    test "valid with required fields" do
      user = insert(:user)

      attrs = %{
        name: "My Telegram Bot",
        user_id: user.id,
        bot_mode: "own"
      }

      changeset = TelegramIntegrationSchema.create_changeset(attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = TelegramIntegrationSchema.create_changeset(%{})
      refute changeset.valid?

      assert %{
               name: ["can't be blank"],
               user_id: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "an empty name is cast to nil and reported as blank, not as a length error" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "",
          user_id: user.id,
          bot_mode: "own"
        })

      refute changeset.valid?
      # cast/3 treats "" as an empty value and drops it, so validate_required
      # fires and the minimum-length rule is never reached. The single error is
      # what the user sees, so it must not be a confusing length complaint.
      assert is_nil(get_change(changeset, :name))
      assert errors_on(changeset).name == ["can't be blank"]
    end

    test "validates name maximum length" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: String.duplicate("a", 101),
          user_id: user.id,
          bot_mode: "own"
        })

      refute changeset.valid?
      assert "should be at most 100 character(s)" in errors_on(changeset).name
    end

    test "validates bot_mode inclusion" do
      user = insert(:user)

      for mode <- ["shared", "own"] do
        changeset =
          TelegramIntegrationSchema.create_changeset(%{
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
        TelegramIntegrationSchema.create_changeset(%{
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
        TelegramIntegrationSchema.create_changeset(%{
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
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own",
          events: ["meeting.created", "invalid.event"]
        })

      refute changeset.valid?
      assert "has an invalid entry" in errors_on(changeset).events
    end

    test "applies default values" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own"
        })

      assert get_field(changeset, :events) == []
      assert get_field(changeset, :is_active) == true
      assert get_field(changeset, :failure_count) == 0
    end
  end

  describe "create_changeset/1 by bot mode" do
    test "takes the bot token and chat id for an own-bot integration" do
      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: insert(:user).id,
          bot_mode: "own",
          bot_token: "test_bot_token_123",
          chat_id: "123456"
        })

      assert get_change(changeset, :chat_id) == "123456"
      assert get_change(changeset, :bot_token_encrypted)
      assert get_change(changeset, :linked_at)
    end

    test "ignores a chat id for a shared-bot integration" do
      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: insert(:user).id,
          bot_mode: "shared",
          chat_id: "123456"
        })

      assert changeset.valid?
      assert get_change(changeset, :chat_id) == nil
      assert get_change(changeset, :linked_at) == nil
    end

    test "ignores link and delivery state" do
      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: insert(:user).id,
          bot_mode: "shared",
          link_token: "forged",
          is_active: false,
          failure_count: 9,
          disabled_reason: "forged"
        })

      assert Map.take(changeset.changes, [:link_token, :link_token_hash]) == %{}
      assert get_field(changeset, :is_active) == true
      assert get_field(changeset, :failure_count) == 0
      assert get_field(changeset, :disabled_reason) == nil
    end
  end

  describe "user_changeset/2" do
    test "never changes the bot mode" do
      integration = insert(:telegram_integration, bot_mode: "own")

      changeset =
        TelegramIntegrationSchema.user_changeset(integration, %{name: "New", bot_mode: "shared"})

      assert changeset.valid?
      assert get_field(changeset, :bot_mode) == "own"
    end

    test "changes the chat id of an own-bot integration" do
      integration = insert(:telegram_integration, bot_mode: "own")

      changeset = TelegramIntegrationSchema.user_changeset(integration, %{chat_id: "424242"})

      assert get_change(changeset, :chat_id) == "424242"
    end

    test "ignores a chat id for a shared-bot integration" do
      integration = insert(:telegram_integration, bot_mode: "shared", chat_id: nil)

      changeset =
        TelegramIntegrationSchema.user_changeset(integration, %{name: "New", chat_id: "424242"})

      assert get_change(changeset, :name) == "New"
      assert get_change(changeset, :chat_id) == nil
      assert get_change(changeset, :linked_at) == nil
    end

    test "ignores delivery state" do
      integration =
        insert(:telegram_integration, failure_count: 0, linked_at: DateTime.utc_now(:second))

      changeset =
        TelegramIntegrationSchema.user_changeset(integration, %{
          failure_count: 9,
          is_active: false
        })

      assert changeset.changes == %{}
    end
  end

  describe "link_changeset/2" do
    test "links a chat and stamps linked_at" do
      integration = insert(:telegram_integration, bot_mode: "shared", chat_id: nil)

      changeset =
        TelegramIntegrationSchema.link_changeset(integration, %{chat_id: "777", link_token: nil})

      assert get_change(changeset, :chat_id) == "777"
      assert get_change(changeset, :linked_at)
    end

    test "ignores the organiser's settings" do
      integration =
        insert(:telegram_integration, name: "Kept", linked_at: DateTime.utc_now(:second))

      changeset =
        TelegramIntegrationSchema.link_changeset(integration, %{
          name: "Changed",
          bot_mode: "shared"
        })

      assert changeset.changes == %{}
    end
  end

  describe "state_transition_changeset/2" do
    test "changes only delivery state" do
      integration = insert(:telegram_integration, chat_id: "123")

      changeset =
        TelegramIntegrationSchema.state_transition_changeset(integration, %{
          is_active: false,
          disabled_reason: "too_many_failures",
          chat_id: "999",
          name: "Changed"
        })

      assert changeset.changes == %{is_active: false, disabled_reason: "too_many_failures"}
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

  describe "encrypt_token/1" do
    test "populates bot_token_encrypted when bot_token is provided" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own",
          bot_token: "test_bot_token_123"
        })

      assert changeset.valid?
      encrypted = get_change(changeset, :bot_token_encrypted)

      refute encrypted == "test_bot_token_123"
      assert Encryption.decrypt(encrypted) == "test_bot_token_123"
    end

    test "does not set bot_token_encrypted when bot_token is empty string" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own",
          bot_token: ""
        })

      assert get_change(changeset, :bot_token_encrypted) == nil
    end

    test "does not set bot_token_encrypted when bot_token is not provided" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own"
        })

      assert get_change(changeset, :bot_token_encrypted) == nil
    end
  end

  describe "decrypt_token/1" do
    test "returns struct unchanged when bot_token_encrypted is nil" do
      integration = %TelegramIntegrationSchema{bot_token_encrypted: nil, bot_token: nil}
      result = TelegramIntegrationSchema.decrypt_token(integration)

      assert result.bot_token == nil
      assert result.bot_token_encrypted == nil
    end

    test "round-trips encrypt and decrypt correctly" do
      user = insert(:user)
      original_token = "test_token_abc"

      changeset =
        TelegramIntegrationSchema.create_changeset(%{
          name: "Bot",
          user_id: user.id,
          bot_mode: "own",
          bot_token: original_token
        })

      encrypted = get_change(changeset, :bot_token_encrypted)
      refute encrypted == original_token

      integration = %TelegramIntegrationSchema{bot_token_encrypted: encrypted}
      result = TelegramIntegrationSchema.decrypt_token(integration)

      assert result.bot_token == original_token
    end
  end
end
