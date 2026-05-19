defmodule Tymeslot.CustomFields.FieldDefinitionTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields
  @moduletag :schema

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.CustomFields.FieldOption

  describe "changeset/2 — common rules" do
    test "auto-generates a UUID id when missing" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "short_text",
          "label" => "Company"
        })

      assert cs.valid?
      assert {:ok, _uuid} = UUID.cast(Changeset.get_field(cs, :id))
    end

    test "label is required" do
      cs = FieldDefinition.changeset(%FieldDefinition{}, %{"type" => "short_text"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).label
    end

    test "label > 120 chars is invalid" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "short_text",
          "label" => String.duplicate("a", 121)
        })

      refute cs.valid?
    end

    test "type must be one of the known kinds" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "rich_text",
          "label" => "X"
        })

      refute cs.valid?
      assert "is invalid" in errors_on(cs).type
    end

    test "preserves an existing id" do
      uuid = UUID.generate()

      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "id" => uuid,
          "type" => "short_text",
          "label" => "X"
        })

      assert Changeset.get_field(cs, :id) == uuid
    end
  end

  describe "changeset/2 — type-specific rules" do
    test "single_select requires at least 2 options" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "single_select",
          "label" => "Pick",
          "options" => [%{"label" => "Only"}]
        })

      refute cs.valid?
    end

    test "single_select accepts 2+ options" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "single_select",
          "label" => "Pick",
          "options" => [%{"label" => "Red"}, %{"label" => "Blue"}]
        })

      assert cs.valid?
    end

    test "note requires non-empty body" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "note",
          "label" => "Terms",
          "body" => ""
        })

      refute cs.valid?
    end

    test "note with body is valid" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "note",
          "label" => "Terms",
          "body" => "Please confirm you have read the terms."
        })

      assert cs.valid?
    end

    test "type change clears all type-specific config (select → short_text)" do
      cs =
        FieldDefinition.changeset(
          %FieldDefinition{
            id: UUID.generate(),
            type: "single_select",
            label: "X",
            options: [
              %FieldOption{key: "a", label: "A"},
              %FieldOption{key: "b", label: "B"}
            ],
            body: nil,
            min: nil,
            max: nil
          },
          %{"type" => "short_text"}
        )

      assert cs.valid?
      assert Changeset.get_field(cs, :options) == []
      assert Changeset.get_field(cs, :body) == nil
      assert Changeset.get_field(cs, :min) == nil
      assert Changeset.get_field(cs, :max) == nil
    end

    test "type change clears min/max (number → single_select)" do
      cs =
        FieldDefinition.changeset(
          %FieldDefinition{
            id: UUID.generate(),
            type: "number",
            label: "Quantity",
            min: 1,
            max: 10
          },
          %{"type" => "single_select", "options" => [%{"label" => "A"}, %{"label" => "B"}]}
        )

      assert cs.valid?
      assert Changeset.get_field(cs, :min) == nil
      assert Changeset.get_field(cs, :max) == nil
    end

    test "multi_select requires at least 2 options" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "multi_select",
          "label" => "Pick many",
          "options" => [%{"label" => "Only"}]
        })

      refute cs.valid?
    end

    test "multi_select accepts 2+ options" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "multi_select",
          "label" => "Pick many",
          "options" => [%{"label" => "Red"}, %{"label" => "Blue"}]
        })

      assert cs.valid?
    end

    test "new short_text record with stray options has options cleared" do
      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "short_text",
          "label" => "Note",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        })

      assert cs.valid?
      assert Changeset.get_field(cs, :options) == []
    end

    test "single_select with 51 options is rejected" do
      options = Enum.map(1..51, fn i -> %{"label" => "Option #{i}"} end)

      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "single_select",
          "label" => "Big list",
          "options" => options
        })

      refute cs.valid?
      assert "should have at most 50 item(s)" in errors_on(cs).options
    end

    test "multi_select with 51 options is rejected" do
      options = Enum.map(1..51, fn i -> %{"label" => "Option #{i}"} end)

      cs =
        FieldDefinition.changeset(%FieldDefinition{}, %{
          "type" => "multi_select",
          "label" => "Big list",
          "options" => options
        })

      refute cs.valid?
      assert "should have at most 50 item(s)" in errors_on(cs).options
    end
  end

  defp errors_on(cs) do
    Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _full, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
