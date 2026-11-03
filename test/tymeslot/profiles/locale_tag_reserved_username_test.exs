defmodule Tymeslot.Profiles.LocaleTagReservedUsernameTest do
  @moduledoc """
  A username shaped like a regional or script locale tag is reserved before
  any such locale launches, since a profile's current username is never
  re-checked; ordinary hyphenated names stay free.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ReservedPaths

  describe "reserved?/1" do
    test "reserves region, numeric region and script tags" do
      for tag <- ~w(pt-pt en-us es-419 zh-hans sr-latn) do
        assert ReservedPaths.reserved?(tag), "expected #{tag} to be reserved"
      end
    end

    test "leaves ordinary hyphenated names free" do
      for name <- ~w(tom-ford max-cole jo-smith ann-li-x a1-bc pt-12 pt-pt-x) do
        refute ReservedPaths.reserved?(name), "expected #{name} to be free"
      end
    end
  end

  describe "choosing a username" do
    test "a locale-tag username is refused and the old one kept" do
      profile = insert(:profile, username: "sarah")

      assert {:error, "This username is reserved"} = Profiles.change_username(profile, "pt-pt")
      assert Profiles.username_status(profile, "pt-pt") == :reserved
      assert {:ok, %{username: "tom-ford"}} = Profiles.change_username(profile, "tom-ford")
    end
  end
end
