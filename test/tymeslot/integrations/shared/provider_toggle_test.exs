defmodule Tymeslot.Integrations.Shared.ProviderToggleTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Shared.ProviderToggle

  describe "enabled?/3" do
    test "returns boolean setting when available" do
      settings = %{google: true, outlook: false}
      assert ProviderToggle.enabled?(settings, :google) == true
      assert ProviderToggle.enabled?(settings, :outlook) == false
    end

    test "handles string keys" do
      settings = %{"google" => true}
      assert ProviderToggle.enabled?(settings, :google) == true
    end

    test "returns default when setting is missing" do
      assert ProviderToggle.enabled?(%{}, :google) == true
      assert ProviderToggle.enabled?(%{}, :google, default_enabled: false) == false
    end

    test "handles keyword list settings" do
      settings = %{google: [enabled: true], outlook: [enabled: false]}
      assert ProviderToggle.enabled?(settings, :google) == true
      assert ProviderToggle.enabled?(settings, :outlook) == false
    end

    test "handles map settings" do
      settings = %{google: %{enabled: true}, outlook: %{enabled: false}}
      assert ProviderToggle.enabled?(settings, :google) == true
      assert ProviderToggle.enabled?(settings, :outlook) == false
    end
  end
end
