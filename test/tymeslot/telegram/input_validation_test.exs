defmodule Tymeslot.Telegram.InputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :telegram
  @moduletag :unit

  alias Tymeslot.Telegram.InputValidation

  describe "validate_bot_token/2" do
    test "accepts valid bot token" do
      {token, errors} =
        InputValidation.validate_bot_token("1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789", %{})

      assert token == "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"
      assert errors == %{}
    end

    test "strips full API URL prefix" do
      {token, errors} =
        InputValidation.validate_bot_token(
          "https://api.telegram.org/bot1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789",
          %{}
        )

      assert token == "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789"
      assert errors == %{}
    end

    test "rejects nil token" do
      {nil, errors} = InputValidation.validate_bot_token(nil, %{})
      assert Map.has_key?(errors, :bot_token)
    end

    test "rejects empty token" do
      {nil, errors} = InputValidation.validate_bot_token("", %{})
      assert Map.has_key?(errors, :bot_token)
    end

    test "rejects invalid format" do
      {nil, errors} = InputValidation.validate_bot_token("not-a-token", %{})
      assert Map.has_key?(errors, :bot_token)
    end
  end

  describe "validate_chat_id/2" do
    test "accepts numeric chat ID" do
      {chat_id, errors} = InputValidation.validate_chat_id("123456789", %{})
      assert chat_id == "123456789"
      assert errors == %{}
    end

    test "accepts negative group chat ID" do
      {chat_id, errors} = InputValidation.validate_chat_id("-1001234567890", %{})
      assert chat_id == "-1001234567890"
      assert errors == %{}
    end

    test "accepts @username format" do
      {chat_id, errors} = InputValidation.validate_chat_id("@mychannel", %{})
      assert chat_id == "@mychannel"
      assert errors == %{}
    end

    test "rejects nil" do
      {nil, errors} = InputValidation.validate_chat_id(nil, %{})
      assert Map.has_key?(errors, :chat_id)
    end

    test "rejects invalid format" do
      {nil, errors} = InputValidation.validate_chat_id("not valid", %{})
      assert Map.has_key?(errors, :chat_id)
    end
  end

  describe "validate_name/2" do
    test "accepts valid name" do
      {name, errors} = InputValidation.validate_name("My Bot", %{})
      assert name == "My Bot"
      assert errors == %{}
    end

    test "rejects nil" do
      {nil, errors} = InputValidation.validate_name(nil, %{})
      assert Map.has_key?(errors, :name)
    end

    test "rejects empty" do
      {nil, errors} = InputValidation.validate_name("", %{})
      assert Map.has_key?(errors, :name)
    end
  end

  describe "validate_events/2" do
    test "accepts valid events" do
      {events, errors} = InputValidation.validate_events(["meeting.created"], %{})
      assert events == ["meeting.created"]
      assert errors == %{}
    end

    test "rejects empty list" do
      {nil, errors} = InputValidation.validate_events([], %{})
      assert Map.has_key?(errors, :events)
    end

    test "rejects invalid events" do
      {nil, errors} = InputValidation.validate_events(["invalid.event"], %{})
      assert Map.has_key?(errors, :events)
    end
  end

  describe "validate_form/2" do
    test "validates own-bot mode form" do
      params = %{
        "name" => "My Bot",
        "bot_token" => "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789",
        "chat_id" => "123456789",
        "events" => ["meeting.created"]
      }

      assert {:ok, sanitized} = InputValidation.validate_form(params, bot_mode: "own")
      assert sanitized.name
      assert sanitized.bot_token
      assert sanitized.chat_id
      assert sanitized.events == ["meeting.created"]
    end

    test "validates shared-bot mode form without token/chat_id" do
      params = %{
        "name" => "My Notifications",
        "events" => ["meeting.created", "meeting.cancelled"]
      }

      assert {:ok, sanitized} = InputValidation.validate_form(params, bot_mode: "shared")
      assert sanitized.name
      assert is_nil(Map.get(sanitized, :bot_token))
      assert sanitized.events
    end

    test "returns errors for missing fields" do
      assert {:error, errors} = InputValidation.validate_form(%{}, bot_mode: "own")
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :bot_token)
      assert Map.has_key?(errors, :chat_id)
      assert Map.has_key?(errors, :events)
    end
  end
end
