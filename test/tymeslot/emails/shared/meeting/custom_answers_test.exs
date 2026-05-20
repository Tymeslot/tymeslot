defmodule Tymeslot.Emails.Shared.Meeting.CustomAnswersTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Ecto.UUID
  alias Tymeslot.Emails.Shared.Meeting.CustomAnswers

  describe "custom_answers_section/1" do
    test "returns empty string when snapshot is nil" do
      html = CustomAnswers.custom_answers_section(%{})
      assert html == ""
    end

    test "returns empty string when snapshot is empty list" do
      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [],
          custom_field_answers: %{}
        })

      assert html == ""
    end

    test "renders section heading when fields are present" do
      field_id = UUID.generate()

      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [
            %{"id" => field_id, "type" => "short_text", "label" => "Company"}
          ],
          custom_field_answers: %{field_id => "Acme"}
        })

      assert html =~ "Additional details"
    end

    test "renders field label and answer value" do
      field_id = UUID.generate()

      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [
            %{"id" => field_id, "type" => "short_text", "label" => "Company"}
          ],
          custom_field_answers: %{field_id => "Acme"}
        })

      assert html =~ "Company"
      assert html =~ "Acme"
    end

    test "renders yes_no field as Yes/No text" do
      field_id = UUID.generate()

      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [
            %{"id" => field_id, "type" => "yes_no", "label" => "Attending?"}
          ],
          custom_field_answers: %{field_id => true}
        })

      assert html =~ "Attending?"
      assert html =~ "Yes"
    end

    test "renders single_select field with option label" do
      field_id = UUID.generate()

      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [
            %{
              "id" => field_id,
              "type" => "single_select",
              "label" => "Topic",
              "options" => [%{"key" => "sales", "label" => "Sales discussion"}]
            }
          ],
          custom_field_answers: %{field_id => "sales"}
        })

      assert html =~ "Topic"
      assert html =~ "Sales discussion"
    end

    test "renders multiple fields in order" do
      id_a = UUID.generate()
      id_b = UUID.generate()

      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [
            %{"id" => id_a, "type" => "short_text", "label" => "Alpha"},
            %{"id" => id_b, "type" => "short_text", "label" => "Beta"}
          ],
          custom_field_answers: %{id_a => "First", id_b => "Second"}
        })

      assert html =~ "Alpha"
      assert html =~ "First"
      assert html =~ "Beta"
      assert html =~ "Second"
      assert String.contains?(html, "Alpha") and String.contains?(html, "Beta")
    end

    test "sanitises XSS in field label" do
      field_id = UUID.generate()

      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [
            %{
              "id" => field_id,
              "type" => "short_text",
              "label" => "<script>alert(1)</script>Label"
            }
          ],
          custom_field_answers: %{field_id => "value"}
        })

      refute html =~ "<script>"
      assert html =~ "Label"
    end

    test "sanitises XSS in answer value" do
      field_id = UUID.generate()

      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [
            %{"id" => field_id, "type" => "short_text", "label" => "Notes"}
          ],
          custom_field_answers: %{field_id => "<img src=x onerror=alert(1)>Safe"}
        })

      refute html =~ "<img src=x"
      assert html =~ "Safe"
    end

    test "renders empty string for unanswered field" do
      field_id = UUID.generate()

      html =
        CustomAnswers.custom_answers_section(%{
          custom_fields_snapshot: [
            %{"id" => field_id, "type" => "short_text", "label" => "Skipped"}
          ],
          custom_field_answers: %{}
        })

      assert html =~ "Skipped"
    end
  end
end
