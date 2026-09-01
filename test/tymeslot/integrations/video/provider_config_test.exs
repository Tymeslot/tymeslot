defmodule Tymeslot.Integrations.Video.ProviderConfigTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.ProviderConfig

  describe "parse/1" do
    test "accepts a valid provider atom" do
      assert ProviderConfig.parse(:mirotalk) == {:ok, :mirotalk}
    end

    test "accepts a valid provider string" do
      assert ProviderConfig.parse("mirotalk") == {:ok, :mirotalk}
    end

    test "accepts :none atom (video-disabled sentinel)" do
      assert ProviderConfig.parse(:none) == {:ok, :none}
    end

    test "accepts \"none\" string (video-disabled sentinel)" do
      assert ProviderConfig.parse("none") == {:ok, :none}
    end

    test "rejects an atom that is known to the VM but not a valid provider" do
      assert ProviderConfig.parse(:totally_unknown_atom) == {:error, :unknown}
    end

    test "rejects a string whose atom has never been created (truly unknown)" do
      assert ProviderConfig.parse("totally_unknown_string_xyzzy") == {:error, :unknown}
    end

    test "rejects a non-string, non-atom value" do
      assert ProviderConfig.parse(42) == {:error, :unknown}
    end

    test "accepts all enabled provider atoms" do
      for provider <- ProviderConfig.all_providers() do
        assert ProviderConfig.parse(provider) == {:ok, provider}
      end
    end

    test "accepts all enabled provider strings" do
      for provider <- ProviderConfig.all_providers() do
        assert ProviderConfig.parse(Atom.to_string(provider)) == {:ok, provider}
      end
    end
  end

  describe "oauth_provider?/1" do
    test "returns true for an OAuth provider atom" do
      assert ProviderConfig.oauth_provider?(:google_meet) == true
    end

    test "returns true for an OAuth provider string" do
      assert ProviderConfig.oauth_provider?("google_meet") == true
    end

    test "returns false for a non-OAuth provider" do
      assert ProviderConfig.oauth_provider?(:mirotalk) == false
    end

    test "returns false for :none" do
      assert ProviderConfig.oauth_provider?(:none) == false
    end

    test "returns false for an invalid input" do
      assert ProviderConfig.oauth_provider?("not_a_provider_xyzzy") == false
    end

    test "returns false for a non-string, non-atom value" do
      assert ProviderConfig.oauth_provider?(42) == false
    end

    test "answers identically for the atom and the string form of every provider" do
      providers = ProviderConfig.provider_constraint_list_all()
      assert providers != []

      disagreeing =
        Enum.reject(providers, fn string ->
          {:ok, atom} = ProviderConfig.parse_known(string)

          ProviderConfig.family_of(atom) == ProviderConfig.family_of(string) and
            ProviderConfig.oauth_provider?(atom) == ProviderConfig.oauth_provider?(string)
        end)

      assert disagreeing == [],
             "these providers get different answers as an atom than as a string: " <>
               inspect(disagreeing)
    end
  end

  describe "family_of/1" do
    test "files each provider under the family that describes it" do
      assert ProviderConfig.family_of(:zoom) == :oauth
      assert ProviderConfig.family_of("zoom") == :oauth
      assert ProviderConfig.family_of(:mirotalk) == :other
      assert ProviderConfig.family_of(:custom) == :other
    end

    test "answers :other for the video-disabled sentinel and for non-providers" do
      assert ProviderConfig.family_of(:none) == :other
      assert ProviderConfig.family_of("not_a_provider_xyzzy") == :other
      assert ProviderConfig.family_of(nil) == :other
    end
  end
end
