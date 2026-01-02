defmodule Tymeslot.Security.FormValidationTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Security.FormValidation

  describe "validate_booking_form/1" do
    test "accepts valid params and returns sanitized values" do
      params = %{
        "name" => "  Alice   Smith  ",
        "email" => "  USER@Example.COM  ",
        "message" => "  Hello   there  "
      }

      assert {:ok, sanitized} = FormValidation.validate_booking_form(params)

      assert sanitized["name"] == "Alice Smith"
      assert sanitized["email"] == "user@example.com"
      assert sanitized["message"] == "Hello there"
    end

    test "requires name" do
      params = %{"name" => "", "email" => "user@example.com", "message" => "Hello"}

      assert {:error, errors} = FormValidation.validate_booking_form(params)
      assert {:name, "Name is required"} in errors
    end

    test "requires email" do
      params = %{"name" => "Alice", "email" => "", "message" => "Hello"}

      assert {:error, errors} = FormValidation.validate_booking_form(params)
      assert {:email, "Email is required"} in errors
    end

    test "enforces name length and format" do
      too_short = %{"name" => "A", "email" => "user@example.com", "message" => "Hello"}
      assert {:error, errors} = FormValidation.validate_booking_form(too_short)
      assert {:name, "Name must be at least 2 characters"} in errors

      too_long_name = String.duplicate("a", 101)
      too_long = %{"name" => too_long_name, "email" => "user@example.com", "message" => "Hello"}
      assert {:error, errors} = FormValidation.validate_booking_form(too_long)
      assert {:name, "Name must be less than 100 characters"} in errors

      invalid_format = %{"name" => "Bob123", "email" => "user@example.com", "message" => "Hello"}
      assert {:error, errors} = FormValidation.validate_booking_form(invalid_format)
      assert {:name, "Name contains invalid characters"} in errors

      valid_international = %{
        "name" => "Łukasz Nowak",
        "email" => "user@example.com",
        "message" => "Hello"
      }

      assert {:ok, _} = FormValidation.validate_booking_form(valid_international)
    end

    test "very long inputs report length errors (not required)" do
      very_long = String.duplicate("a", 20_000)

      assert {:error, errors} =
               FormValidation.validate_booking_form(%{
                 "name" => very_long,
                 "email" => "user@example.com",
                 "message" => "Hello"
               })

      assert {:name, "Name must be less than 100 characters"} in errors
      refute {:name, "Name is required"} in errors

      assert {:error, errors} =
               FormValidation.validate_booking_form(%{
                 "name" => "Alice",
                 "email" => very_long,
                 "message" => "Hello"
               })

      assert {:email, "Email address is too long"} in errors
      refute {:email, "Email is required"} in errors

      assert {:error, errors} =
               FormValidation.validate_booking_form(%{
                 "name" => "Alice",
                 "email" => "user@example.com",
                 "message" => very_long
               })

      assert {:message, "Message must be less than 2000 characters"} in errors
    end

    test "enforces email format and length" do
      invalid = %{"name" => "Alice", "email" => "not-an-email", "message" => "Hello"}
      assert {:error, errors} = FormValidation.validate_booking_form(invalid)
      assert {:email, "Please enter a valid email address"} in errors

      long_local = String.duplicate("a", 245)
      too_long_email = long_local <> "@example.com"
      params = %{"name" => "Alice", "email" => too_long_email, "message" => "Hello"}

      assert {:error, errors} = FormValidation.validate_booking_form(params)
      assert {:email, "Email address is too long"} in errors
    end

    test "treats message as optional and enforces maximum length" do
      no_message = %{"name" => "Alice", "email" => "user@example.com"}
      assert {:ok, sanitized} = FormValidation.validate_booking_form(no_message)
      assert sanitized["message"] == ""

      too_long = String.duplicate("a", 2001)
      params = %{"name" => "Alice", "email" => "user@example.com", "message" => too_long}

      assert {:error, errors} = FormValidation.validate_booking_form(params)
      assert {:message, "Message must be less than 2000 characters"} in errors
    end

    test "rejects messages containing dangerous event-handler patterns" do
      params = %{
        "name" => "Alice",
        "email" => "user@example.com",
        "message" => "This looks like onerror = something"
      }

      assert {:error, errors} = FormValidation.validate_booking_form(params)
      assert {:message, "Message contains invalid content"} in errors
    end

    test "accepts simple rich text content" do
      params = %{
        "name" => "Alice",
        "email" => "user@example.com",
        "message" => "<b>Hello</b> world"
      }

      assert {:ok, sanitized} = FormValidation.validate_booking_form(params)
      assert is_binary(sanitized["message"])
      refute sanitized["message"] == ""
    end
  end

  describe "sanitize_booking_params/1" do
    test "returns a predictable map and never raises on missing keys" do
      assert {:ok, sanitized} = FormValidation.sanitize_booking_params(%{})

      assert Enum.sort(Map.keys(sanitized)) == ["email", "message", "name"]
      assert sanitized["name"] == ""
      assert sanitized["email"] == ""
      assert sanitized["message"] == ""
    end

    test "normalizes whitespace in name and lowercases email" do
      params = %{"name" => "  Alice   Smith  ", "email" => "  USER@Example.COM  ", "message" => nil}

      assert {:ok, sanitized} = FormValidation.sanitize_booking_params(params)
      assert sanitized["name"] == "Alice Smith"
      assert sanitized["email"] == "user@example.com"
      assert sanitized["message"] == ""
    end
  end

  describe "validate_booking_params/1" do
    test "accepts an already-sanitized valid payload" do
      params = %{"name" => "Alice Smith", "email" => "user@example.com", "message" => ""}

      assert {:ok, ^params} = FormValidation.validate_booking_params(params)
    end

    test "returns user-facing errors for invalid payload" do
      params = %{"name" => "", "email" => "not-an-email", "message" => ""}

      assert {:error, errors} = FormValidation.validate_booking_params(params)
      assert {:name, "Name is required"} in errors
      assert {:email, "Please enter a valid email address"} in errors
    end
  end

  describe "URL/date/time helpers" do
    test "validate_duration/1 accepts allowed values" do
      assert {:ok, 15} = FormValidation.validate_duration("15")
      assert {:ok, 30} = FormValidation.validate_duration("30")
      assert {:ok, 60} = FormValidation.validate_duration("60")
      assert {:error, "Invalid duration"} = FormValidation.validate_duration("45")
      assert {:error, "Invalid duration"} = FormValidation.validate_duration(45)
    end

    test "validate_date/1 validates iso8601 dates within allowed range" do
      today = Date.utc_today()

      assert {:ok, ^today} = FormValidation.validate_date(Date.to_iso8601(today))

      past = Date.add(today, -1)
      assert {:error, "Date cannot be in the past"} = FormValidation.validate_date(Date.to_iso8601(past))

      too_far = Date.add(today, 366)
      assert {:error, "Date cannot be more than a year in the future"} =
               FormValidation.validate_date(Date.to_iso8601(too_far))

      assert {:error, "Invalid date format"} = FormValidation.validate_date("not-a-date")
      assert {:error, "Invalid date"} = FormValidation.validate_date(123)
    end

    test "validate_time/1 validates HH:MM format" do
      assert {:ok, ~T[09:30:00]} = FormValidation.validate_time("09:30")
      assert {:error, "Invalid time format"} = FormValidation.validate_time("9:30")
      assert {:error, "Invalid time"} = FormValidation.validate_time(nil)
    end
  end

  describe "error helpers" do
    test "get_field_errors/2 extracts messages for a given field" do
      errors = [
        {:email, "Email is required"},
        {:name, "Name is required"},
        {:email, "Please enter a valid email address"}
      ]

      assert FormValidation.get_field_errors(errors, :email) == [
               "Email is required",
               "Please enter a valid email address"
             ]

      assert FormValidation.get_field_errors(errors, :name) == ["Name is required"]
      assert FormValidation.get_field_errors(errors, :message) == []
    end

    test "has_errors?/1 and field_has_errors?/2 reflect presence correctly" do
      errors = [{:email, "Email is required"}]

      assert FormValidation.has_errors?(errors)
      refute FormValidation.has_errors?([])

      assert FormValidation.field_has_errors?(errors, :email)
      refute FormValidation.field_has_errors?(errors, :name)
    end
  end
end
