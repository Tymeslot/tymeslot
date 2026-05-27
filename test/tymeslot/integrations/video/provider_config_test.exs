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
  end
end
