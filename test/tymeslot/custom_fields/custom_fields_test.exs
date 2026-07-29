defmodule Tymeslot.CustomFieldsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :custom_fields

  alias Tymeslot.CustomFields

  describe "validate_answers/2" do
    test "ok when all required answers are valid" do
      snapshot = [
        %{"id" => "a", "type" => "short_text", "label" => "Company", "required" => true},
        %{"id" => "b", "type" => "yes_no", "label" => "Confirm", "required" => true}
      ]

      answers = %{"a" => "Acme", "b" => true}

      assert {:ok, normalised} = CustomFields.validate_answers(snapshot, answers)
      assert normalised == %{"a" => "Acme", "b" => true}
    end

    test "errors when a required answer is missing" do
      snapshot = [
        %{"id" => "a", "type" => "short_text", "label" => "Company", "required" => true}
      ]

      assert {:error, errs} = CustomFields.validate_answers(snapshot, %{})
      assert errs == %{"a" => "Text is required"}
    end

    test "errors when a required answer is invalid" do
      snapshot = [
        %{
          "id" => "x",
          "type" => "single_select",
          "label" => "Pick",
          "required" => true,
          "options" => [%{"key" => "red", "label" => "Red"}]
        }
      ]

      assert {:error, errs} = CustomFields.validate_answers(snapshot, %{"x" => "blue"})
      assert Map.has_key?(errs, "x")
    end

    test "optional fields can be empty" do
      snapshot = [
        %{"id" => "a", "type" => "short_text", "label" => "Notes", "required" => false}
      ]

      assert {:ok, normalised} = CustomFields.validate_answers(snapshot, %{})
      # Optional field with no answer: validator returns :ok with nil, so the
      # normalised map carries the id with a nil value. Pin this contract.
      assert normalised == %{"a" => nil}
    end

    test "extra answer keys not in snapshot are silently dropped" do
      snapshot = [
        %{"id" => "a", "type" => "short_text", "label" => "Company", "required" => true}
      ]

      assert {:ok, normalised} =
               CustomFields.validate_answers(snapshot, %{"a" => "Acme", "extra" => "garbage"})

      refute Map.has_key?(normalised, "extra")
    end

    test "rejects an answer that exceeds the defensive raw length cap" do
      snapshot = [
        %{"id" => "a", "type" => "short_text", "label" => "Notes", "required" => false}
      ]

      huge = String.duplicate("x", 6_000)
      assert {:error, errs} = CustomFields.validate_answers(snapshot, %{"a" => huge})
      assert Map.has_key?(errs, "a")
    end

    test "multi_select answers are stored deduped and canonicalised" do
      snapshot = [
        %{
          "id" => "m",
          "type" => "multi_select",
          "label" => "Pick",
          "required" => true,
          "options" => [%{"key" => "a", "label" => "A"}, %{"key" => "b", "label" => "B"}]
        }
      ]

      assert {:ok, normalised} =
               CustomFields.validate_answers(snapshot, %{"m" => ["a", "a", "b"]})

      assert Enum.sort(normalised["m"]) == ["a", "b"]
    end

    test "aggregates multiple errors" do
      snapshot = [
        %{"id" => "a", "type" => "short_text", "label" => "Company", "required" => true},
        %{"id" => "b", "type" => "yes_no", "label" => "Confirm", "required" => true}
      ]

      assert {:error, errs} = CustomFields.validate_answers(snapshot, %{})
      assert Map.has_key?(errs, "a")
      assert Map.has_key?(errs, "b")
    end
  end

  describe "snapshot_for/1 and validate_answer/2 delegates" do
    test "snapshot_for/1 delegates to Snapshot.from_meeting_type/1" do
      mt = %{custom_fields: []}
      assert CustomFields.snapshot_for(mt) == []
    end

    test "validate_answer/2 delegates to Validator.validate/2" do
      d = %{"type" => "short_text", "required" => true, "label" => "X"}
      assert {:ok, "Acme"} = CustomFields.validate_answer("Acme", d)
    end
  end
end
