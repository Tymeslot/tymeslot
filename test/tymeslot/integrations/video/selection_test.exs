defmodule Tymeslot.Integrations.Video.SelectionTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Discovery
  alias Tymeslot.Integrations.Video.Selection

  describe "providers_with_capability/1" do
    test "returns providers with screen sharing capability" do
      providers = Selection.providers_with_capability(:screen_sharing)

      assert :mirotalk in providers
      assert :google_meet in providers
    end

    test "returns providers with recording capability" do
      providers = Selection.providers_with_capability(:recording)

      assert :google_meet in providers
      # MiroTalk declares `recording: false`, so it must be filtered out
      refute :mirotalk in providers
    end

    test "excludes providers that do not support a waiting room" do
      providers = Selection.providers_with_capability(:waiting_room)

      refute :mirotalk in providers
      refute :google_meet in providers
    end

    test "returns empty list for nonexistent capability" do
      providers = Selection.providers_with_capability(:nonexistent_capability)

      assert providers == []
    end

    test "returns valid provider atoms" do
      providers = Selection.providers_with_capability(:screen_sharing)

      Enum.each(providers, fn provider ->
        assert provider in [:mirotalk, :google_meet, :teams, :custom, :zoom]
      end)
    end

    test "providers with capability are subset of all providers" do
      all_providers = Discovery.list_available_providers()
      all_types = Enum.map(all_providers, & &1.type)

      providers_with_screen_sharing = Selection.providers_with_capability(:screen_sharing)

      # All providers with capability should be in the full provider list
      Enum.each(providers_with_screen_sharing, fn provider ->
        assert provider in all_types
      end)
    end
  end

  # `recommend_provider/1` currently ignores its requirements and always returns
  # the registry's default provider. These tests pin that documented contract:
  # they will fail loudly if requirement-aware selection is ever implemented
  # without updating the expectations here.
  describe "recommend_provider/1" do
    test "returns recommended provider for default requirements" do
      assert Selection.recommend_provider() == :mirotalk
    end

    test "returns recommended provider for small meeting" do
      requirements = %{
        participant_count: 5,
        recording_required: false
      }

      assert Selection.recommend_provider(requirements) == :mirotalk
    end

    test "returns recommended provider for large meeting" do
      requirements = %{
        participant_count: 50,
        recording_required: true
      }

      assert Selection.recommend_provider(requirements) == :mirotalk
    end

    test "returns recommended provider for recording required" do
      requirements = %{
        recording_required: true
      }

      assert Selection.recommend_provider(requirements) == :mirotalk
    end

    test "returns recommended provider for screen sharing required" do
      requirements = %{
        screen_sharing_required: true
      }

      assert Selection.recommend_provider(requirements) == :mirotalk
    end

    test "returns consistent recommendation for same requirements" do
      requirements = %{
        participant_count: 10,
        recording_required: false
      }

      provider1 = Selection.recommend_provider(requirements)
      provider2 = Selection.recommend_provider(requirements)

      assert provider1 == provider2
    end

    test "returns valid provider even with empty requirements" do
      assert Selection.recommend_provider(%{}) == :mirotalk
    end

    test "recommended provider is in available providers list" do
      provider = Selection.recommend_provider()
      all_providers = Discovery.list_available_providers()
      all_types = Enum.map(all_providers, & &1.type)

      assert provider in all_types
    end
  end
end
