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

    test "a ticked note shows the tick without the stored UTC timestamp" do
      assert "✓ Acknowledged" =
               AnswerRenderer.render(
                 %{"type" => "note"},
                 %{"confirmed" => true, "confirmed_at" => "2026-05-13T23:30:00Z"}
               )
    end

    test "a ticked note is translated" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert "✓ Bestätigt" =
                 AnswerRenderer.render(
                   %{"type" => "note"},
                   %{"confirmed" => true, "confirmed_at" => "2026-05-13T12:00:00Z"}
                 )
      end)
    end

    test "a date answer is written out in English" do
      Gettext.with_locale(TymeslotWeb.Gettext, "en", fn ->
        assert "January 19, 2027" = AnswerRenderer.render(%{"type" => "date"}, "2027-01-19")
      end)
    end

    test "a date answer follows the ambient locale" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert "19. Januar 2027" = AnswerRenderer.render(%{"type" => "date"}, "2027-01-19")
      end)
    end

    test "a date answer that does not parse is shown as stored" do
      assert "next week" = AnswerRenderer.render(%{"type" => "date"}, "next week")
    end

    test "a time answer is shown as stored" do
      assert "09:00" = AnswerRenderer.render(%{"type" => "time"}, "09:00")
    end

    test "short_text returns the value as-is" do
      assert "Acme" = AnswerRenderer.render(%{"type" => "short_text"}, "Acme")
    end

    test "nil value returns empty string for any type" do
      assert "" = AnswerRenderer.render(%{"type" => "short_text"}, nil)
    end
  end
end
