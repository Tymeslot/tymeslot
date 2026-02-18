defmodule Tymeslot.Utils.ChangesetUtilsTest do
  @moduletag :utils
  use ExUnit.Case, async: true
  alias Tymeslot.Utils.ChangesetUtils

  # Dummy schema for testing changesets
  defmodule User do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :email, :string
      field :name, :string
      field :age, :integer
    end

    @type t :: %__MODULE__{
            email: String.t() | nil,
            name: String.t() | nil,
            age: integer() | nil
          }

    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(user, attrs) do
      user
      |> cast(attrs, [:email, :name, :age])
      |> validate_required([:email, :name])
      |> validate_length(:name, min: 3)
      |> validate_number(:age, greater_than: 18)
    end
  end

  describe "format_errors/1" do
    test "formats multiple errors into a human-readable string" do
      changeset = User.changeset(%User{}, %{email: "", name: "ab", age: 10})

      formatted = ChangesetUtils.format_errors(changeset)

      assert formatted =~ "email: can't be blank"
      assert formatted =~ "name: should be at least 3 character(s)"
      assert formatted =~ "age: must be greater than 18"
      assert String.contains?(formatted, "; ")
    end

    test "returns empty string for valid changeset" do
      changeset = User.changeset(%User{}, %{email: "test@example.com", name: "John Doe", age: 25})
      assert ChangesetUtils.format_errors(changeset) == ""
    end
  end

  describe "get_first_error/1" do
    test "returns the first humanized error message deterministically (alphabetical by field)" do
      # Both email and name are required. "email" comes before "name" alphabetically.
      changeset = User.changeset(%User{}, %{})

      error = ChangesetUtils.get_first_error(changeset)

      assert error == "Email can't be blank"
    end

    test "returns nil for valid changeset" do
      changeset = User.changeset(%User{}, %{email: "test@example.com", name: "John Doe"})
      assert ChangesetUtils.get_first_error(changeset) == nil
    end
  end

  describe "get_error_list/1" do
    test "returns a list of humanized error messages" do
      changeset = User.changeset(%User{}, %{email: "", name: "ab"})

      errors = ChangesetUtils.get_error_list(changeset)

      assert Enum.any?(errors, fn e -> e == "Email can't be blank" end)
      assert Enum.any?(errors, fn e -> e == "Name should be at least 3 character(s)" end)
      assert length(errors) == 2
    end

    test "returns empty list for valid changeset" do
      changeset = User.changeset(%User{}, %{email: "test@example.com", name: "John Doe"})
      assert ChangesetUtils.get_error_list(changeset) == []
    end
  end
end
