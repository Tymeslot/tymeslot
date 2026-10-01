defmodule Tymeslot.Emails.Shared.TextBodyHelperTest do
  use ExUnit.Case, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.TextBodyHelper

  describe "format_custom_answers/2" do
    @details %{
      custom_fields_snapshot: [
        %{"id" => "start", "type" => "date", "label" => "Start"},
        %{"id" => "terms", "type" => "note", "label" => "Terms"}
      ],
      custom_field_answers: %{
        "start" => "2027-01-19",
        "terms" => %{"confirmed" => true, "confirmed_at" => "2027-01-02T09:00:00Z"}
      }
    }

    test "writes a date answer out in the recipient's locale" do
      assert TextBodyHelper.format_custom_answers(@details, "de") =~ "Start: 19. Januar 2027"
      assert TextBodyHelper.format_custom_answers(@details, "en") =~ "Start: January 19, 2027"
    end

    test "shows a ticked note without its timestamp" do
      text = TextBodyHelper.format_custom_answers(@details, "de")

      assert text =~ "Terms: ✓ Bestätigt\n"
      refute text =~ "2027-01-02"
    end
  end
end
