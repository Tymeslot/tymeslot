defmodule Tymeslot.CustomFields.AnswerRendererTest do
  use Tymeslot.DataCase, async: true

  @moduletag :custom_fields

  alias Tymeslot.CustomFields.AnswerRenderer

  describe "render/2" do
    test "yes_no true → Yes" do
      assert "Yes" = AnswerRenderer.render(%{"type" => "yes_no"}, true)
    end

    test "yes_no anything-else → No" do
      assert "No" = AnswerRenderer.render(%{"type" => "yes_no"}, false)
      assert "No" = AnswerRenderer.render(%{"type" => "yes_no"}, nil)
    end

    test "single_select returns the label for the matched key" do
      d = %{
        "type" => "single_select",
        "options" => [
          %{"key" => "red", "label" => "Red"},
          %{"key" => "blue", "label" => "Blue"}
        ]
      }

      assert "Red" = AnswerRenderer.render(d, "red")
    end

    test "single_select with unknown key returns the raw value" do
      d = %{"type" => "single_select", "options" => [%{"key" => "red", "label" => "Red"}]}
      assert "green" = AnswerRenderer.render(d, "green")
    end

    test "single_select with nil returns empty string" do
      d = %{"type" => "single_select", "options" => [%{"key" => "red", "label" => "Red"}]}
      assert "" = AnswerRenderer.render(d, nil)
    end

    test "multi_select joins labels with comma" do
      d = %{
        "type" => "multi_select",
        "options" => [
          %{"key" => "a", "label" => "Apple"},
          %{"key" => "b", "label" => "Banana"},
          %{"key" => "c", "label" => "Cherry"}
        ]
      }

      assert "Apple, Cherry" = AnswerRenderer.render(d, ["a", "c"])
    end

    test "note returns acknowledgement string with timestamp" do
      assert "✓ Acknowledged (2026-05-13T12:00:00Z)" =
               AnswerRenderer.render(
                 %{"type" => "note"},
                 %{"confirmed" => true, "confirmed_at" => "2026-05-13T12:00:00Z"}
               )
    end

    test "short_text returns the value as-is" do
      assert "Acme" = AnswerRenderer.render(%{"type" => "short_text"}, "Acme")
    end

    test "nil value returns empty string for any type" do
      assert "" = AnswerRenderer.render(%{"type" => "short_text"}, nil)
    end
  end
end
