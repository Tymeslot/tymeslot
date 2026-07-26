defmodule Tymeslot.Integrations.Video.SelectionTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Discovery
  alias Tymeslot.Integrations.Video.Selection

  describe "providers_with_capability/1" do
    test "returns providers with screen sharing capability" do
      assert_capability(:screen_sharing, [:mirotalk, :google_meet, :teams, :zoom])
    end

    test "returns providers with recording capability" do
      assert_capability(:recording, [:google_meet, :teams, :zoom])
    end

    test "returns providers with waiting room capability" do
      assert_capability(:waiting_room, [:teams, :zoom])
    end

    test "returns empty list for nonexistent capability" do
      assert Selection.providers_with_capability(:nonexistent_capability) == []
    end

    test "returns valid provider atoms" do
      providers = Selection.providers_with_capability(:screen_sharing)

      Enum.each(providers, fn provider ->
        assert is_atom(provider)
        assert provider in [:mirotalk, :google_meet, :teams, :zoom, :custom]
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

    defp assert_capability(capability, supporting) do
      registered = Enum.map(Discovery.list_available_providers(), & &1.type)
      expected = supporting |> Enum.filter(&(&1 in registered)) |> Enum.sort()

      assert Enum.sort(Selection.providers_with_capability(capability)) == expected
    end
  end

  describe "recommend_provider/1" do
    test "returns recommended provider for default requirements" do
      provider = Selection.recommend_provider()

      assert is_atom(provider)
      assert provider in [:mirotalk, :google_meet, :teams, :custom]
    end

    test "returns recommended provider for small meeting" do
      requirements = %{
        participant_count: 5,
        recording_required: false
      }

      provider = Selection.recommend_provider(requirements)

      assert is_atom(provider)
      assert provider in [:mirotalk, :google_meet, :teams, :custom]
    end

    test "returns recommended provider for large meeting" do
      requirements = %{
        participant_count: 50,
        recording_required: true
      }

      provider = Selection.recommend_provider(requirements)

      assert is_atom(provider)
      assert provider in [:mirotalk, :google_meet, :teams, :custom]
    end

    test "returns recommended provider for recording required" do
      requirements = %{
        recording_required: true
      }

      provider = Selection.recommend_provider(requirements)

      assert is_atom(provider)
    end

    test "returns recommended provider for screen sharing required" do
      requirements = %{
        screen_sharing_required: true
      }

      provider = Selection.recommend_provider(requirements)

      assert is_atom(provider)
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
      provider = Selection.recommend_provider(%{})

      assert is_atom(provider)
      assert provider in [:mirotalk, :google_meet, :teams, :custom]
    end

    test "recommended provider is in available providers list" do
      provider = Selection.recommend_provider()
      all_providers = Discovery.list_available_providers()
      all_types = Enum.map(all_providers, & &1.type)

      assert provider in all_types
    end
  end
end
