defmodule TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliserTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  alias TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliser

  test "string \"true\" coerces to boolean true" do
    assert AnswerNormaliser.normalise("true") == true
  end

  test "string \"false\" coerces to boolean false" do
    assert AnswerNormaliser.normalise("false") == false
  end

  test "\"acknowledge\" produces a confirmed map with a UTC confirmed_at timestamp" do
    result = AnswerNormaliser.normalise("acknowledge")

    assert %{"confirmed" => true, "confirmed_at" => confirmed_at} = result
    assert {:ok, dt, _} = DateTime.from_iso8601(confirmed_at)
    assert dt.time_zone == "Etc/UTC"
  end

  test "other string values pass through unchanged" do
    assert AnswerNormaliser.normalise("some text") == "some text"
  end

  test "nil passes through unchanged" do
    assert AnswerNormaliser.normalise(nil) == nil
  end

  test "integer passes through unchanged" do
    assert AnswerNormaliser.normalise(42) == 42
  end

  test "map passes through unchanged" do
    value = %{"confirmed" => true, "confirmed_at" => "2025-01-01T00:00:00Z"}
    assert AnswerNormaliser.normalise(value) == value
  end
end
