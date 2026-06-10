defmodule TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliserTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  alias TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliser

  describe "type-aware coercion" do
    test "\"true\" coerces to boolean true for yes_no" do
      assert AnswerNormaliser.normalise("true", "yes_no") == true
    end

    test "\"false\" coerces to boolean false for yes_no" do
      assert AnswerNormaliser.normalise("false", "yes_no") == false
    end

    test "\"acknowledge\" produces a confirmed map with a UTC timestamp for note" do
      result = AnswerNormaliser.normalise("acknowledge", "note")

      assert %{"confirmed" => true, "confirmed_at" => confirmed_at} = result
      assert {:ok, dt, _offset} = DateTime.from_iso8601(confirmed_at)
      assert dt.time_zone == "Etc/UTC"
    end
  end

  describe "text-like questions keep token words verbatim" do
    test "\"true\" typed into short_text passes through unchanged" do
      assert AnswerNormaliser.normalise("true", "short_text") == "true"
    end

    test "\"false\" typed into a phone question passes through unchanged" do
      assert AnswerNormaliser.normalise("false", "phone") == "false"
    end

    test "\"acknowledge\" typed into a url question passes through unchanged" do
      assert AnswerNormaliser.normalise("acknowledge", "url") == "acknowledge"
    end

    test "tokens with no type given are not coerced" do
      assert AnswerNormaliser.normalise("true", nil) == "true"
      assert AnswerNormaliser.normalise("acknowledge", nil) == "acknowledge"
    end
  end

  describe "non-token values pass through unchanged" do
    test "ordinary text" do
      assert AnswerNormaliser.normalise("some text", "short_text") == "some text"
    end

    test "nil" do
      assert AnswerNormaliser.normalise(nil, "short_text") == nil
    end

    test "integer" do
      assert AnswerNormaliser.normalise(42, "number") == 42
    end

    test "map" do
      value = %{"confirmed" => true, "confirmed_at" => "2025-01-01T00:00:00Z"}
      assert AnswerNormaliser.normalise(value, "note") == value
    end
  end
end
