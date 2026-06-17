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

    test "note overrides the client confirmed_at with a server-side timestamp" do
      d = %{"type" => "note", "label" => "Terms", "body" => "Be nice."}
      # A crafted client timestamp far in the past must be ignored.
      forged = "2000-01-01T00:00:00Z"
      payload = %{"confirmed" => true, "confirmed_at" => forged}

      assert {:ok, %{"confirmed" => true, "confirmed_at" => stamped}} =
               Validator.validate(payload, d)

      refute stamped == forged
      assert {:ok, dt, 0} = DateTime.from_iso8601(stamped)
      # The server stamp is recent (within the last minute).
      assert DateTime.diff(DateTime.utc_now(), dt) <= 60
    end

    test "optional note left blank is accepted" do
      d = %{"type" => "note", "label" => "Terms", "body" => "Be nice.", "required" => false}
      assert {:ok, nil} = Validator.validate(nil, d)
    end

    test "multi_select dedupes and canonicalises to the option set" do
      d = %{
        "type" => "multi_select",
        "label" => "Pick",
        "options" => [%{"key" => "a", "label" => "A"}, %{"key" => "b", "label" => "B"}]
      }

      assert {:ok, keys} = Validator.validate(["a", "a", "b", "a"], d)
      assert Enum.sort(keys) == ["a", "b"]
      assert length(keys) == 2
    end

    test "short_text keeps literal token words verbatim" do
      # Type-aware normalisation lives in the theme layer; the validator must
      # accept these as plain text without coercion.
      d = %{"type" => "short_text", "required" => true, "label" => "Word"}
      assert {:ok, "true"} = Validator.validate("true", d)
      assert {:ok, "false"} = Validator.validate("false", d)
      assert {:ok, "acknowledge"} = Validator.validate("acknowledge", d)
    end

    test "number bounds supplied as strings are enforced" do
      d = %{"type" => "number", "label" => "Qty", "min" => "1", "max" => "10"}
      assert {:ok, "5"} = Validator.validate("5", d)
      assert {:error, _msg} = Validator.validate("0", d)
      assert {:error, _msg} = Validator.validate("11", d)
    end

    test "date bounds supplied as ISO strings are enforced" do
      d = %{"type" => "date", "label" => "When", "min" => "2026-01-01", "max" => "2026-12-31"}
      assert {:ok, "2026-06-01"} = Validator.validate("2026-06-01", d)
      assert {:error, _msg} = Validator.validate("2025-12-31", d)
      assert {:error, _msg} = Validator.validate("2027-01-01", d)
    end

    test "an over-long text answer is rejected" do
      d = %{"type" => "short_text", "required" => true, "label" => "X"}
      assert {:error, _msg} = Validator.validate(String.duplicate("x", 3_000), d)
    end

    test "unknown type returns error" do
      d = %{"type" => "rich_text", "required" => true, "label" => "Bad"}
      assert {:error, _msg} = Validator.validate("anything", d)
    end
  end
end
