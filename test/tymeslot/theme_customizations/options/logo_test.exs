defmodule Tymeslot.ThemeCustomizations.Options.LogoTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Logo

  @group %{key: :logo, module: Logo}

  defp changeset(attrs),
    do: {%{}, Logo.types()} |> Changeset.change() |> Logo.changeset(attrs, @group)

  describe "changeset/3" do
    test "casts the stored logo path" do
      changeset = changeset(%{"logo_path" => "themes/1/98/images/a-logo.png"})

      assert changeset.valid?
      assert Changeset.get_change(changeset, :logo_path) == "themes/1/98/images/a-logo.png"
    end

    test "takes nothing of another group's settings" do
      assert changeset(%{"background_type" => "color", "cover_path" => "x.png"}).changes == %{}
    end
  end

  describe "changes/3" do
    test "removing the logo clears its path, so the save deletes the file" do
      assert Logo.changes("logo_path", "", @group) == {:ok, %{"logo_path" => nil}}
    end

    test "refuses a path chosen rather than uploaded, and any other field" do
      assert Logo.changes("logo_path", "themes/1/98/images/a-logo.png", @group) == :error
      assert Logo.changes("logo", "", @group) == :error
    end
  end

  describe "uploads" do
    test "declare one image field, which an upload fills and nothing else" do
      assert Logo.asset_fields(@group) == [logo_path: :image]

      assert Logo.upload_changes(:logo_path, "themes/1/98/images/b-logo.png", @group) ==
               %{"logo_path" => "themes/1/98/images/b-logo.png"}
    end
  end

  describe "media/2" do
    test "is the uploaded logo's URL, under :logo" do
      assert Logo.media(%{"logo_path" => "themes/1/98/images/a-logo.png"}, @group) ==
               %{logo: %{src: "/uploads/themes/1/98/images/a-logo.png"}}
    end

    test "sanitises the stored path as an uploaded background's is" do
      assert Logo.media(%{"logo_path" => "themes/1/98/images/../<b>.png"}, @group) ==
               %{logo: %{src: "/uploads/themes/1/98/images/b.png"}}
    end

    test "is nil without a logo" do
      assert Logo.media(%{}, @group) == %{logo: nil}
      assert Logo.media(%{"logo_path" => ""}, @group) == %{logo: nil}
    end
  end
end
