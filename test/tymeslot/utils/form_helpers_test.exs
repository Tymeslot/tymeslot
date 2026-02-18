defmodule Tymeslot.Utils.FormHelpersTest do
  @moduletag :utils
  use ExUnit.Case, async: true
  alias Tymeslot.Utils.FormHelpers

  # Dummy schema for testing changesets
  defmodule Item do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :title, :string
      field :count, :integer
    end

    @type t :: %__MODULE__{
            title: String.t() | nil,
            count: integer() | nil
          }

    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(item, attrs) do
      item
      |> cast(attrs, [:title, :count])
      |> validate_required([:title])
      |> validate_number(:count, greater_than: 0)
    end
  end

  describe "format_changeset_errors/1" do
    test "formats changeset errors into a map of field -> messages" do
      changeset = Item.changeset(%Item{}, %{title: "", count: 0})

      errors = FormHelpers.format_changeset_errors(changeset)

      assert errors == %{
               title: ["can't be blank"],
               count: ["must be greater than 0"]
             }
    end

    test "returns empty map for valid changeset" do
      changeset = Item.changeset(%Item{}, %{title: "Valid Title"})
      assert FormHelpers.format_changeset_errors(changeset) == %{}
    end
  end

  describe "format_context_error/1" do
    test "formats known error atoms" do
      assert FormHelpers.format_context_error(:video_integration_required) ==
               %{video_integration: ["Please select a video provider for video meetings"]}

      assert FormHelpers.format_context_error(:invalid_duration) ==
               %{duration: ["Duration must be a valid number"]}
    end

    test "formats generic atoms to capitalized base error" do
      assert FormHelpers.format_context_error(:something_went_wrong) ==
               %{base: ["Something went wrong"]}
    end

    test "formats non-atom errors to string base error" do
      assert FormHelpers.format_context_error("string error") ==
               %{base: ["string error"]}
    end
  end
end
