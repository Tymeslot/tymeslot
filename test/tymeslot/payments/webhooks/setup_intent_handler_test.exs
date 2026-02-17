defmodule Tymeslot.Payments.Webhooks.SetupIntentHandlerTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Payments.Webhooks.SetupIntentHandler

  describe "can_handle?/1" do
    test "returns true for supported setup intent events" do
      assert SetupIntentHandler.can_handle?("setup_intent.created")
      assert SetupIntentHandler.can_handle?("setup_intent.succeeded")
    end

    test "returns false for unsupported events" do
      refute SetupIntentHandler.can_handle?("setup_intent.canceled")
    end
  end

  describe "validate/1" do
    test "returns :ok for valid setup intent" do
      assert SetupIntentHandler.validate(%{"id" => "seti_123"}) == :ok
    end

    test "returns error for missing or empty id" do
      assert {:error, :missing_field, _reason} = SetupIntentHandler.validate(%{})
      assert {:error, :missing_field, _reason} = SetupIntentHandler.validate(%{"id" => ""})
    end
  end

  describe "process/2" do
    test "acknowledges setup intent event" do
      setup_intent = %{"id" => "seti_123"}
      event = %{"type" => "setup_intent.created"}

      assert {:ok, :setup_intent_processed} =
               SetupIntentHandler.process(event, setup_intent)
    end
  end
end
