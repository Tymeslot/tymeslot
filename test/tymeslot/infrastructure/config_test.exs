defmodule Tymeslot.Infrastructure.ConfigTest do
  use ExUnit.Case, async: true
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.AppConfig
  alias Tymeslot.Infrastructure.Config

  describe "app_config_module/0" do
    test "returns default module when not configured" do
      assert Config.app_config_module() == AppConfig
    end

    test "returns default module when configured module is not loaded" do
      Application.put_env(:tymeslot, :app_config_module, NonExistentModule)
      on_exit(fn -> Application.delete_env(:tymeslot, :app_config_module) end)

      assert Config.app_config_module() == AppConfig
    end
  end

  describe "AppConfig default values" do
    test "enforce_legal_agreements? returns configured value" do
      expected = Application.get_env(:tymeslot, :enforce_legal_agreements, false)
      assert AppConfig.enforce_legal_agreements?() == expected
    end

    test "show_marketing_links? returns configured value" do
      expected = Application.get_env(:tymeslot, :show_marketing_links, false)
      assert AppConfig.show_marketing_links?() == expected
    end

    test "logo_links_to_marketing? returns configured value" do
      expected = Application.get_env(:tymeslot, :logo_links_to_marketing, false)
      assert AppConfig.logo_links_to_marketing?() == expected
    end

    test "site_home_path returns configured value" do
      expected = Application.get_env(:tymeslot, :site_home_path, "/dashboard")
      assert AppConfig.site_home_path() == expected
    end
  end

  describe "Config delegation" do
    test "enforce_legal_agreements? delegates to app_config_module" do
      assert Config.enforce_legal_agreements?() == AppConfig.enforce_legal_agreements?()
    end

    test "show_marketing_links? delegates to app_config_module" do
      assert Config.show_marketing_links?() == AppConfig.show_marketing_links?()
    end

    test "logo_links_to_marketing? delegates to app_config_module" do
      assert Config.logo_links_to_marketing?() == AppConfig.logo_links_to_marketing?()
    end

    test "site_home_path delegates to app_config_module" do
      assert Config.site_home_path() == AppConfig.site_home_path()
    end
  end
end
