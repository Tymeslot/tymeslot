defmodule Tymeslot.CustomFields.FieldOptionTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  alias Tymeslot.CustomFields.FieldOption

  describe "changeset/2" do
    test "valid option with key and label" do
      attrs = %{"key" => "red", "label" => "Red"}
      cs = FieldOption.changeset(%FieldOption{}, attrs)
      assert cs.valid?
    end

    test "missing label is invalid" do
      cs = FieldOption.changeset(%FieldOption{}, %{"key" => "red"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).label
    end

    test "label longer than 80 chars is invalid" do
      attrs = %{"key" => "x", "label" => String.duplicate("a", 81)}
      cs = FieldOption.changeset(%FieldOption{}, attrs)
      refute cs.valid?
    end

    test "auto-generates a key when missing" do
      cs = FieldOption.changeset(%FieldOption{}, %{"label" => "Bright Red"})
      assert get_change(cs, :key) |> is_binary()
      assert String.length(get_change(cs, :key)) > 0
    end
  end

  defp errors_on(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp get_change(cs, field), do: Ecto.Changeset.get_change(cs, field)
end
