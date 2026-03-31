defmodule Tymeslot.Validation.ConstraintsTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Validation.Constraints

  @moduletag :unit

  describe "scheduling ranges" do
    test "buffer_minutes_range returns 0..120" do
      assert Constraints.buffer_minutes_range() == 0..120
    end

    test "advance_booking_days_range returns 1..365" do
      assert Constraints.advance_booking_days_range() == 1..365
    end

    test "min_advance_hours_range returns 0..168" do
      assert Constraints.min_advance_hours_range() == 0..168
    end

    test "duration_minutes_range returns 1..480" do
      assert Constraints.duration_minutes_range() == 1..480
    end
  end

  describe "Ecto-ready options" do
    test "buffer_minutes_opts" do
      opts = Constraints.buffer_minutes_opts()
      assert opts[:greater_than_or_equal_to] == 0
      assert opts[:less_than_or_equal_to] == 120
    end

    test "advance_booking_days_opts" do
      opts = Constraints.advance_booking_days_opts()
      assert opts[:greater_than_or_equal_to] == 1
      assert opts[:less_than_or_equal_to] == 365
    end

    test "min_advance_hours_opts" do
      opts = Constraints.min_advance_hours_opts()
      assert opts[:greater_than_or_equal_to] == 0
      assert opts[:less_than_or_equal_to] == 168
    end

    test "duration_minutes_opts" do
      opts = Constraints.duration_minutes_opts()
      assert opts[:greater_than] == 0
      assert opts[:less_than_or_equal_to] == 480
    end
  end

  describe "field lengths" do
    test "email_max_length is RFC 5321 compliant" do
      assert Constraints.email_max_length() == 254
    end

    test "url_max_length" do
      assert Constraints.url_max_length() == 2048
    end

    test "username_length_range" do
      assert Constraints.username_length_range() == 3..30
    end

    test "password_length_range" do
      assert Constraints.password_length_range() == 8..80
    end

    test "webhook_name_length_range" do
      assert Constraints.webhook_name_length_range() == 1..255
    end

    test "integration_name_length_range" do
      assert Constraints.integration_name_length_range() == 2..100
    end

    test "description_max_length" do
      assert Constraints.description_max_length() == 500
    end

    test "name_length_range" do
      assert Constraints.name_length_range() == 1..100
    end

    test "message_length_range" do
      assert Constraints.message_length_range() == 10..2000
    end
  end
end
