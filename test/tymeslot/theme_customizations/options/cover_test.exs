defmodule Tymeslot.ThemeCustomizations.Options.CoverTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Cover
  alias Tymeslot.ThemeCustomizations.Presets

  @group %{
    key: :cover,
    module: Cover,
    presets: ["ocean-sunset", "artistic-studio"],
    default: "ocean-sunset"
  }

  defp changeset(attrs),
    do: {%{}, Cover.types()} |> Changeset.change() |> Cover.changeset(attrs, @group)

  defp preset_src(id), do: Presets.find_preset_by_id(:cover, id).src

  describe "changeset/3" do
    test "accepts a cover the group offers" do
      assert changeset(%{"cover_value" => "artistic-studio"}).valid?
    end

    test "refuses a cover the group does not offer, even one the catalogue holds" do
      changeset = changeset(%{"cover_value" => "elegant-still-life"})
      assert {"must be a valid cover preset", _opts} = changeset.errors[:cover_value]
    end

    test "a custom cover needs its uploaded file" do
      assert {"is required for an uploaded cover", _opts} =
               changeset(%{"cover_value" => "custom"}).errors[:cover_path]

      assert changeset(%{"cover_value" => "custom", "cover_path" => "themes/1/98/images/a.png"}).valid?
    end

    test "no stored cover is valid: the group's default stands in" do
      assert changeset(%{}).valid?
    end
  end

  describe "changes/3" do
    test "choosing an offered cover drops an uploaded one, so the save deletes its file" do
      assert Cover.changes("cover_value", "artistic-studio", @group) ==
               {:ok, %{"cover_value" => "artistic-studio", "cover_path" => nil}}
    end

    test "refuses a cover the group does not offer, the custom value and other fields" do
      assert Cover.changes("cover_value", "elegant-still-life", @group) == :error
      assert Cover.changes("cover_value", "custom", @group) == :error
      assert Cover.changes("cover_path", "", @group) == :error
    end
  end

  describe "uploads" do
    test "an upload into the one image field becomes the custom cover" do
      assert Cover.asset_fields(@group) == [cover_path: :image]

      assert Cover.upload_changes(:cover_path, "themes/1/98/images/a-cover.png", @group) ==
               %{"cover_value" => "custom", "cover_path" => "themes/1/98/images/a-cover.png"}
    end
  end

  describe "media/2" do
    test "a preset is its image, with its id" do
      assert Cover.media(%{"cover_value" => "artistic-studio"}, @group) ==
               %{cover: %{src: preset_src("artistic-studio"), preset: "artistic-studio"}}
    end

    test "an upload is its sanitised URL, with no preset" do
      settings = %{"cover_value" => "custom", "cover_path" => "themes/1/98/images/../<b>.png"}

      assert Cover.media(settings, @group) ==
               %{cover: %{src: "/uploads/themes/1/98/images/b.png", preset: nil}}
    end

    test "with nothing stored, is the group's default" do
      assert Cover.media(%{}, @group) ==
               %{cover: %{src: preset_src("ocean-sunset"), preset: "ocean-sunset"}}
    end

    test "a stored preset the group no longer lists still renders" do
      assert %{cover: %{preset: "rustic-farmhouse"}} =
               Cover.media(%{"cover_value" => "rustic-farmhouse"}, @group)
    end

    test "is nil when the stored value resolves to nothing" do
      assert Cover.media(%{"cover_value" => "custom"}, @group) == %{cover: nil}
      assert Cover.media(%{"cover_value" => "no-such-cover"}, @group) == %{cover: nil}
    end
  end

  describe "presets/1" do
    test "are the group's covers in its order, leaving out an id the catalogue lacks" do
      group = %{@group | presets: ["artistic-studio", "nope", "ocean-sunset"]}
      assert Enum.map(Cover.presets(group), &elem(&1, 0)) == ["artistic-studio", "ocean-sunset"]
    end
  end
end
