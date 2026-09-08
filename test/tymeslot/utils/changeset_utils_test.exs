defmodule Tymeslot.Utils.ChangesetUtilsTest do
  use ExUnit.Case, async: true

  @moduletag :utils

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
end
