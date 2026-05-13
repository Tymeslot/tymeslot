defmodule Tymeslot.CustomFields.SnapshotTest do
  use Tymeslot.DataCase, async: true

  @moduletag :custom_fields

  alias Tymeslot.CustomFields.{FieldDefinition, FieldOption, Snapshot}

  test "from_meeting_type/1 returns the definitions as plain maps" do
    mt = %{
      custom_fields: [
        %FieldDefinition{
          id: "a",
          type: "short_text",
          label: "Company",
          required: true,
          options: [],
          position: 0
        }
      ]
    }

    [out] = Snapshot.from_meeting_type(mt)
    assert out["id"] == "a"
    assert out["type"] == "short_text"
    assert out["label"] == "Company"
    assert out["required"] == true
    assert out["options"] == []
    assert out["position"] == 0
  end

  test "from_meeting_type/1 serialises embedded options" do
    mt = %{
      custom_fields: [
        %FieldDefinition{
          id: "f1",
          type: "single_select",
          label: "Pick",
          required: true,
          options: [%FieldOption{key: "r", label: "Red"}],
          position: 0
        }
      ]
    }

    [out] = Snapshot.from_meeting_type(mt)
    assert out["options"] == [%{"key" => "r", "label" => "Red"}]
  end

  test "from_meeting_type/1 sorts by position" do
    mt = %{
      custom_fields: [
        %FieldDefinition{id: "b", type: "short_text", label: "B", position: 2},
        %FieldDefinition{id: "a", type: "short_text", label: "A", position: 1}
      ]
    }

    [first, second] = Snapshot.from_meeting_type(mt)
    assert first["id"] == "a"
    assert second["id"] == "b"
  end

  test "from_meeting_type/1 with no custom_fields returns []" do
    assert Snapshot.from_meeting_type(%{}) == []
    assert Snapshot.from_meeting_type(%{custom_fields: nil}) == []
  end

  test "from_definitions/1 is a no-op for plain maps" do
    plain = [%{"id" => "x", "type" => "short_text", "label" => "X"}]
    assert Snapshot.from_definitions(plain) == plain
  end

  test "from_definitions/1 sorts atom-keyed plain maps by position" do
    defs = [
      %{id: "b", type: "short_text", label: "B", position: 2},
      %{id: "a", type: "short_text", label: "A", position: 1}
    ]

    [first, _second] = Snapshot.from_definitions(defs)
    assert first["id"] == "a"
  end

  test "from_definitions/1 strips nil-valued keys" do
    mt = %{
      custom_fields: [
        %FieldDefinition{
          id: "a",
          type: "short_text",
          label: "X",
          help_text: nil,
          body: nil,
          min: nil,
          max: nil
        }
      ]
    }

    [out] = Snapshot.from_meeting_type(mt)
    refute Map.has_key?(out, "help_text")
    refute Map.has_key?(out, "body")
    refute Map.has_key?(out, "min")
    refute Map.has_key?(out, "max")
  end
end
