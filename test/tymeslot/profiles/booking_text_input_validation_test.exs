defmodule Tymeslot.Profiles.BookingTextInputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduledoc """
  The booking text is organiser-authored prose bound for a public page. It has
  to survive the punctuation real copy contains while still being refused when
  the bytes themselves are malformed, which is the split between the plain-text
  sanitiser and the strict one.
  """
  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Profiles.InputValidation

  describe "punctuation that strict sanitisation would mangle" do
    test "keeps apostrophes, quotes, dashes and angle brackets intact" do
      params = %{
        "booking_heading" => "Let's talk -- properly",
        "booking_greeting" => ~s(Hi! I'm "Sam" <the founder>),
        "booking_instruction" => "Pick a slot; I'll confirm within 24h."
      }

      assert {:ok, out} = InputValidation.validate_booking_text(params)
      assert out["booking_heading"] == "Let's talk -- properly"
      assert out["booking_greeting"] == ~s(Hi! I'm "Sam" <the founder>)
      assert out["booking_instruction"] == "Pick a slot; I'll confirm within 24h."
    end

    test "keeps non-Latin scripts and emoji" do
      params = %{"booking_heading" => "Давайте поговоримо 👋"}

      assert {:ok, %{"booking_heading" => "Давайте поговоримо 👋"}} =
               InputValidation.validate_booking_text(params)
    end
  end

  describe "what it does remove" do
    test "strips null bytes, which Postgres rejects" do
      params = %{"booking_heading" => "Let's\x00 talk"}

      assert {:ok, %{"booking_heading" => heading}} =
               InputValidation.validate_booking_text(params)

      refute heading =~ "\x00"
    end

    test "trims surrounding whitespace" do
      assert {:ok, %{"booking_heading" => "Let's talk"}} =
               InputValidation.validate_booking_text(%{"booking_heading" => "  Let's talk  "})
    end

    test "refuses malformed encoding rather than storing it" do
      params = %{"booking_heading" => <<0xFF, 0xFE, "broken">>}

      assert {:error, %{booking_heading: _message}} =
               InputValidation.validate_booking_text(params)
    end

    test "refuses a value that is not text at all" do
      assert {:error, %{booking_greeting: _message}} =
               InputValidation.validate_booking_text(%{"booking_greeting" => 42})
    end
  end

  describe "fields it leaves alone" do
    test "passes through params the form did not submit" do
      params = %{"booking_text_enabled" => "false"}

      assert {:ok, ^params} = InputValidation.validate_booking_text(params)
    end

    test "never touches keys outside the three text fields" do
      params = %{"booking_heading" => "Hi", "username" => "  spaced  "}

      assert {:ok, %{"username" => "  spaced  "}} =
               InputValidation.validate_booking_text(params)
    end
  end
end
