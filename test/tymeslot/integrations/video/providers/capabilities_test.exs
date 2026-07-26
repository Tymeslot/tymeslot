defmodule Tymeslot.Integrations.Video.Providers.CapabilitiesTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  describe "provider capability vocabulary" do
    test "every provider declares only keys from the shared vocabulary" do
      for {type, module} <- ProviderConfig.providers_map() do
        unknown = Map.keys(module.capabilities()) -- Capabilities.known_keys()

        assert unknown == [],
               "#{type} declares capability keys outside the vocabulary: #{inspect(unknown)}"
      end
    end

    test "every provider answers all universal capability keys" do
      for {type, module} <- ProviderConfig.providers_map() do
        missing = Capabilities.universal_keys() -- Map.keys(module.capabilities())

        assert missing == [],
               "#{type} does not declare universal capability keys: #{inspect(missing)}"
      end
    end

    test "no provider declares a supports_-prefixed variant of a vocabulary key" do
      for {type, module} <- ProviderConfig.providers_map(),
          key <- Map.keys(module.capabilities()) do
        refute String.starts_with?(Atom.to_string(key), "supports_"),
               "#{type} reintroduced a prefixed capability key: #{inspect(key)}"
      end
    end
  end

  describe "new!/1" do
    test "builds a map when the contract is satisfied" do
      assert Capabilities.new!(universal_attrs()) == Map.new(universal_attrs())
    end

    test "raises on a key outside the vocabulary" do
      assert_raise ArgumentError, ~r/unknown video capability keys.*supports_recording/, fn ->
        Capabilities.new!(universal_attrs() ++ [supports_recording: true])
      end
    end

    test "raises when a universal key is missing" do
      assert_raise ArgumentError, ~r/missing video capability keys.*waiting_room/, fn ->
        Capabilities.new!(Keyword.delete(universal_attrs(), :waiting_room))
      end
    end

    test "raises on a duplicated key" do
      assert_raise ArgumentError, ~r/duplicate video capability keys.*recording/, fn ->
        Capabilities.new!(universal_attrs() ++ [recording: false])
      end
    end

    defp universal_attrs do
      [
        breakout_rooms: false,
        chat: true,
        dial_in: false,
        max_participants: 10,
        recording: true,
        screen_sharing: true,
        waiting_room: false
      ]
    end
  end

  describe "providers_with_capability/1 across all providers" do
    test "reports every provider that supports screen sharing" do
      assert_capability(:screen_sharing, [:mirotalk, :google_meet, :teams, :zoom])
    end

    test "reports every provider that supports recording" do
      assert_capability(:recording, [:google_meet, :teams, :zoom])
    end

    test "reports every provider that supports a waiting room" do
      assert_capability(:waiting_room, [:teams, :zoom])
    end

    test "reports every provider that supports chat" do
      assert_capability(:chat, [:mirotalk, :google_meet, :teams, :zoom])
    end

    test "reports every provider that supports breakout rooms" do
      assert_capability(:breakout_rooms, [:google_meet, :teams, :zoom])
    end

    test "reports every provider that supports dial-in" do
      assert_capability(:dial_in, [:google_meet, :teams, :zoom])
    end

    test "returns an empty list for a capability outside the vocabulary" do
      assert ProviderRegistry.providers_with_capability(:nonexistent_capability) == []
    end

    defp assert_capability(capability, supporting) do
      registered = ProviderRegistry.list_providers()
      expected = supporting |> Enum.filter(&(&1 in registered)) |> Enum.sort()

      assert Enum.sort(ProviderRegistry.providers_with_capability(capability)) == expected
    end
  end
end
