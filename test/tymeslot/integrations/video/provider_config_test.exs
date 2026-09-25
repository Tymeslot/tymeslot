defmodule Tymeslot.Integrations.Video.ProviderConfigTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.Providers.KmeetProvider
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider

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

  describe "valid_provider?/1" do
    test "returns true for valid video providers" do
      assert ProviderConfig.valid_provider?(:mirotalk)
      assert ProviderConfig.valid_provider?(:google_meet)
      assert ProviderConfig.valid_provider?(:custom)
      assert ProviderConfig.valid_provider?(:zoom)
    end

    test "returns false for unknown providers and non-atoms" do
      refute ProviderConfig.valid_provider?(:invalid)
      refute ProviderConfig.valid_provider?(:unknown)
      refute ProviderConfig.valid_provider?("mirotalk")
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

  describe "kmeet and jitsi registration" do
    test "both parse from their string form" do
      assert {:ok, :kmeet} = ProviderConfig.parse_known("kmeet")
      assert {:ok, :jitsi} = ProviderConfig.parse_known("jitsi")
    end

    test "both are link-based, not OAuth" do
      refute ProviderConfig.oauth_provider?(:kmeet)
      refute ProviderConfig.oauth_provider?(:jitsi)
    end

    test "both carry a display name and metadata" do
      assert ProviderConfig.display_name(:kmeet) == "kMeet"
      assert ProviderConfig.display_name(:jitsi) == "Jitsi Meet"
    end

    test "both agree with their provider module's hardcoded display name and type" do
      assert ProviderConfig.display_name(:kmeet) == KmeetProvider.display_name()
      assert ProviderConfig.display_name(:jitsi) == JitsiProvider.display_name()
      assert KmeetProvider.provider_type() == :kmeet
      assert JitsiProvider.provider_type() == :jitsi
    end

    test "both appear in the changeset constraint list" do
      list = ProviderConfig.provider_constraint_list_all()
      assert "kmeet" in list
      assert "jitsi" in list
    end

    test "both resolve to a provider module" do
      assert ProviderConfig.get_provider_module(:kmeet) == KmeetProvider
      assert ProviderConfig.get_provider_module(:jitsi) == JitsiProvider
    end
  end

  describe "rooms_updated_on_reschedule?/1" do
    # A provider that can update a room is one whose room holds the meeting's
    # time or name, so the list and the callback cannot disagree.
    test "is true exactly for the providers whose module can update a room" do
      for provider <- ProviderConfig.known_providers() do
        module = ProviderConfig.get_provider_module(provider)
        Code.ensure_loaded!(module)

        assert ProviderConfig.rooms_updated_on_reschedule?(provider) ==
                 function_exported?(module, :update_meeting_room, 2),
               "#{provider} disagrees with its module"
      end

      assert Enum.filter(
               ProviderConfig.known_providers(),
               &ProviderConfig.rooms_updated_on_reschedule?/1
             ) == [:teams, :zoom, :nextcloud_talk]
    end

    test "answers the stored string form as the atom" do
      assert ProviderConfig.rooms_updated_on_reschedule?("nextcloud_talk")
      refute ProviderConfig.rooms_updated_on_reschedule?("jitsi")
      refute ProviderConfig.rooms_updated_on_reschedule?("unknown")
    end
  end

  describe "nextcloud_talk registration" do
    test "parses from its string form and is not OAuth" do
      assert {:ok, :nextcloud_talk} = ProviderConfig.parse_known("nextcloud_talk")
      refute ProviderConfig.oauth_provider?(:nextcloud_talk)
    end

    test "carries its display name and module" do
      assert ProviderConfig.display_name(:nextcloud_talk) == "Nextcloud Talk"
      assert ProviderConfig.get_provider_module(:nextcloud_talk) == NextcloudTalkProvider
    end

    test "is accepted by the changeset's provider constraint" do
      assert "nextcloud_talk" in ProviderConfig.provider_constraint_list_all()
    end

    test "runs its API calls behind the circuit breaker" do
      assert ProviderConfig.circuit_breaker_enabled?(:nextcloud_talk)
    end
  end
end
