defmodule Tymeslot.ChangesetValidators.EmailTest do
  use ExUnit.Case, async: true

  alias __MODULE__.EmailHolder
  alias Ecto.Changeset
  alias Tymeslot.ChangesetValidators.Email

  @moduletag :unit

  defmodule EmailHolder do
    use Ecto.Schema

    embedded_schema do
      field(:email, :string)
      field(:secondary_email, :string)
    end
  end

  defp changeset(attrs) do
    Changeset.change(%EmailHolder{}, attrs)
  end

  describe "validate_email/3" do
    test "valid email passes" do
      cs = changeset(%{email: "user@example.com"})
      result = Email.validate_email(cs, :email)
      assert result.valid?
    end

    test "invalid email fails with EmailValidator message" do
      cs = changeset(%{email: "not-an-email"})
      result = Email.validate_email(cs, :email)
      refute result.valid?
      assert Keyword.has_key?(result.errors, :email)
    end

    test "works with different field names" do
      cs = changeset(%{secondary_email: "bad"})
      result = Email.validate_email(cs, :secondary_email)
      refute result.valid?
      assert Keyword.has_key?(result.errors, :secondary_email)
    end

    test "skips validation when field has not changed" do
      cs = Changeset.change(%EmailHolder{email: "old@example.com"}, %{})
      result = Email.validate_email(cs, :email)
      assert result.valid?
    end
  end
end
