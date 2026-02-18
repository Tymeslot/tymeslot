defmodule Tymeslot.Integrations.Shared.ProviderConfigHelperTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Shared.ProviderConfigHelper

  describe "effective_providers/4" do
    test "filters by enabled status" do
      providers = [:google, :outlook]
      dev_only = [:local]

      enabled_fun = fn
        :google -> true
        :outlook -> false
        :local -> true
      end

      # No dev
      assert ProviderConfigHelper.effective_providers(providers, dev_only, false, enabled_fun) ==
               [:google]

      # With dev
      assert ProviderConfigHelper.effective_providers(providers, dev_only, true, enabled_fun) == [
               :google,
               :local
             ]
    end
  end

  describe "validate_required_fields/2" do
    test "returns :ok when all fields are present" do
      assert :ok = ProviderConfigHelper.validate_required_fields(%{a: 1, b: 2}, [:a])
    end

    test "returns error when fields are missing" do
      assert {:error, message} = ProviderConfigHelper.validate_required_fields(%{a: 1}, [:a, :b])
      assert message =~ "Missing required fields: b"
    end
  end
end
