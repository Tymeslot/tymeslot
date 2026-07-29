defmodule TymeslotWeb.Live.Scheduling.BookingConfigTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :unit

  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.Live.Scheduling.BookingConfig

  describe "booking_field_spec/0" do
    test "accepts valid booking params" do
      params = %{"name" => "Alice", "email" => "alice@example.com", "message" => "Hello"}

      assert {:ok, sanitized} =
               InputProcessor.validate_form(params, BookingConfig.booking_field_spec())

      assert sanitized["name"] == "Alice"
      assert sanitized["email"] == "alice@example.com"
    end

    test "rejects missing required fields" do
      params = %{"name" => "", "email" => "", "message" => ""}

      assert {:error, errors} =
               InputProcessor.validate_form(params, BookingConfig.booking_field_spec())

      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :email)
    end

    test "message field is optional" do
      params = %{"name" => "Alice", "email" => "alice@example.com", "message" => ""}

      assert {:ok, _sanitized} =
               InputProcessor.validate_form(params, BookingConfig.booking_field_spec())
    end
  end
end
