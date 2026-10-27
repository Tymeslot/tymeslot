defmodule Tymeslot.Security.FieldValidators.DisplayNameValidationTest do
  @moduledoc """
  The optional display name: `NameValidator` with `required: false,
  min_length: 1`, as the `:full_name` field type resolves to.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.NameValidator
  alias Tymeslot.Security.InputProcessor

  @display_name [required: false, min_length: 1]

  describe "validate/2" do
    test "returns :ok for valid full names" do
      assert :ok = NameValidator.validate("John Smith", @display_name)
      assert :ok = NameValidator.validate("José María", @display_name)
      assert :ok = NameValidator.validate("O'Connor", @display_name)
      assert :ok = NameValidator.validate("Anne-Marie", @display_name)
    end

    test "returns :ok for nil or empty string (optional field)" do
      assert :ok = NameValidator.validate(nil, @display_name)
      assert :ok = NameValidator.validate("", @display_name)
      assert :ok = NameValidator.validate("   ", @display_name)
    end

    test "returns error for long names" do
      long_name = String.duplicate("a", 101)

      assert {:error, "Name is too long (maximum 100 characters)"} =
               NameValidator.validate(long_name, @display_name)
    end

    test "returns error for invalid characters" do
      assert {:error, "Name contains invalid characters"} =
               NameValidator.validate("John<script>", @display_name)

      assert {:error, "Name contains invalid characters"} =
               NameValidator.validate("Name;", @display_name)
    end

    test "returns error for only numbers" do
      assert {:error, "Name cannot be only numbers"} =
               NameValidator.validate("12345", @display_name)

      assert {:error, "Name cannot be only numbers"} =
               NameValidator.validate("123 45", @display_name)
    end

    test "returns error for excessive whitespace" do
      assert {:error, "Name contains excessive whitespace"} =
               NameValidator.validate("John   Smith", @display_name)
    end

    test "supports custom max_length option" do
      assert {:error, "Name is too long (maximum 5 characters)"} =
               NameValidator.validate("Too long", Keyword.put(@display_name, :max_length, 5))
    end

    test "returns error for non-binary values" do
      assert {:error, "Name must be a text value"} = NameValidator.validate(123, @display_name)

      assert {:error, "Name must be a text value"} =
               NameValidator.validate(%{key: "value"}, @display_name)
    end
  end

  # The same validator serves the profile's "Display Name" and the
  # onboarding's "Your name", so its messages say "Name", which reads right
  # under either label, in every locale.
  describe "validate/2 in another language" do
    test "names the field neutrally" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert {:error, "Name darf nicht nur aus Zahlen bestehen"} =
                 NameValidator.validate("12345", @display_name)
      end)
    end
  end

  describe "the :full_name field type" do
    test "is optional and takes a one-letter name" do
      assert {:ok, ""} = InputProcessor.validate_field("", :full_name)
      assert {:ok, "Q"} = InputProcessor.validate_field("Q", :full_name)

      assert {:error, "Name cannot be only numbers"} =
               InputProcessor.validate_field("123", :full_name)
    end
  end
end
