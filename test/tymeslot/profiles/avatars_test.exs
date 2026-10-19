defmodule Tymeslot.Profiles.AvatarsTest do
  use ExUnit.Case, async: true

  @moduletag :profiles

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Avatars

  describe "fallback_data_uri/2" do
    test "draws the initials of a profile-shaped map" do
      assert decode(Avatars.fallback_data_uri(%{id: 7, full_name: "Ada Lovelace", user: nil})) =~
               ">AL</text>"
    end

    test "is what Profiles.fallback_avatar_data_uri/2 returns" do
      profile = %{id: 3, full_name: "Grace Hopper", user: nil}

      assert Profiles.fallback_avatar_data_uri(profile) == Avatars.fallback_data_uri(profile)
      assert decode(Profiles.fallback_avatar_data_uri(profile, 64)) =~ ">GH</text>"
    end

    test "draws a generic avatar without a profile" do
      assert decode(Avatars.fallback_data_uri(nil)) =~ ">U</text>"
    end
  end

  defp decode("data:image/svg+xml;base64," <> encoded), do: Base.decode64!(encoded)
end
