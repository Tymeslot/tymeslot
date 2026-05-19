defmodule Tymeslot.CustomFields.ValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :custom_fields

  alias Tymeslot.CustomFields.Validator

  describe "validate/2 — dispatches by type" do
    test "short_text accepts any non-blank text" do
      d = %{"type" => "short_text", "required" => true, "label" => "Company"}
      assert {:ok, "Acme"} = Validator.validate("Acme", d)
      assert {:error, _msg} = Validator.validate("", d)
    end

    test "short_text accepts a single-character answer" do
      d = %{"type" => "short_text", "required" => true, "label" => "Initial"}
      assert {:ok, "A"} = Validator.validate("A", d)
    end

    test "short_text accepts an all-numeric answer" do
      d = %{"type" => "short_text", "required" => true, "label" => "Reference"}
      assert {:ok, "12345"} = Validator.validate("12345", d)
    end

    test "short_text blank optional answer is accepted" do
      d = %{"type" => "short_text", "required" => false, "label" => "Notes"}
      assert {:ok, ""} = Validator.validate("", d)
    end

    test "yes_no accepts both true and false; missing answer fails when required" do
      d = %{"type" => "yes_no", "required" => true, "label" => "Attending?"}
      assert {:ok, true} = Validator.validate(true, d)
      assert {:ok, false} = Validator.validate(false, d)
      assert {:error, _msg} = Validator.validate(nil, d)
    end

    test "single_select must be a known key" do
      d = %{
        "type" => "single_select",
        "required" => true,
        "label" => "Pick",
        "options" => [%{"key" => "a", "label" => "A"}, %{"key" => "b", "label" => "B"}]
      }

      assert {:ok, "a"} = Validator.validate("a", d)
      assert {:error, _msg} = Validator.validate("c", d)
    end

    test "note returns confirmed_at as a UTC ISO string when ok" do
      d = %{"type" => "note", "label" => "Terms", "body" => "Be nice."}
      ts = DateTime.to_iso8601(DateTime.utc_now())
      payload = %{"confirmed" => true, "confirmed_at" => ts}
      assert {:ok, ^payload} = Validator.validate(payload, d)
    end

    test "unknown type returns error" do
      d = %{"type" => "rich_text", "required" => true, "label" => "Bad"}
      assert {:error, _msg} = Validator.validate("anything", d)
    end
  end
end
