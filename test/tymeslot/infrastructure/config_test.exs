defmodule Tymeslot.Infrastructure.ConfigTest.SingleFlagStub do
  @moduledoc false
  # A stand-in app-config module in which exactly one boolean flag is true at a
  # time: the one named in `:stub_flag`. A `Config` delegation wired to the
  # wrong callback therefore returns `false` and the assertion fails, which a
  # stub returning the same value for every flag could never catch.

  @behaviour Tymeslot.Infrastructure.AppConfigBehaviour

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  @spec registration_enabled?() :: boolean()
  def registration_enabled?, do: on?(:registration_enabled)

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  @spec password_auth_enabled?() :: boolean()
  def password_auth_enabled?, do: on?(:password_auth_enabled)

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  @spec enforce_legal_agreements?() :: boolean()
  def enforce_legal_agreements?, do: on?(:enforce_legal_agreements)

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  @spec show_marketing_links?() :: boolean()
  def show_marketing_links?, do: on?(:show_marketing_links)

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  @spec logo_links_to_marketing?() :: boolean()
  def logo_links_to_marketing?, do: on?(:logo_links_to_marketing)

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  @spec site_home_path() :: String.t()
  def site_home_path, do: "/stub-home"

  defp on?(flag), do: Application.get_env(:tymeslot, :stub_flag) == flag
end

defmodule Tymeslot.Infrastructure.ConfigTest do
  # async: false — these tests swap the globally configured app-config module
  # and individual config keys, which every concurrently running test that
  # reads `Config.*` or `AppConfig.*` would otherwise see.
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.AppConfig
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.ConfigTest.SingleFlagStub

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

  describe "AppConfig" do
    test "enforce_legal_agreements? reads its key and defaults to off" do
      assert with_key(:enforce_legal_agreements, true, &AppConfig.enforce_legal_agreements?/0)
      refute with_key(:enforce_legal_agreements, false, &AppConfig.enforce_legal_agreements?/0)
      refute without_key(:enforce_legal_agreements, &AppConfig.enforce_legal_agreements?/0)
    end

    test "show_marketing_links? reads its key and defaults to off" do
      assert with_key(:show_marketing_links, true, &AppConfig.show_marketing_links?/0)
      refute with_key(:show_marketing_links, false, &AppConfig.show_marketing_links?/0)
      refute without_key(:show_marketing_links, &AppConfig.show_marketing_links?/0)
    end

    test "logo_links_to_marketing? reads its key and defaults to off" do
      assert with_key(:logo_links_to_marketing, true, &AppConfig.logo_links_to_marketing?/0)
      refute with_key(:logo_links_to_marketing, false, &AppConfig.logo_links_to_marketing?/0)
      refute without_key(:logo_links_to_marketing, &AppConfig.logo_links_to_marketing?/0)
    end

    test "site_home_path reads its key and defaults to the dashboard" do
      assert with_key(:site_home_path, "/elsewhere", &AppConfig.site_home_path/0) == "/elsewhere"
      assert without_key(:site_home_path, &AppConfig.site_home_path/0) == "/dashboard"
    end
  end

  describe "Config delegation" do
    setup do
      Application.put_env(:tymeslot, :app_config_module, SingleFlagStub)

      on_exit(fn ->
        Application.delete_env(:tymeslot, :app_config_module)
        Application.delete_env(:tymeslot, :stub_flag)
      end)

      :ok
    end

    test "enforce_legal_agreements? delegates to the matching callback" do
      Application.put_env(:tymeslot, :stub_flag, :enforce_legal_agreements)

      assert Config.enforce_legal_agreements?()
      refute Config.show_marketing_links?()
      refute Config.logo_links_to_marketing?()
    end

    test "show_marketing_links? delegates to the matching callback" do
      Application.put_env(:tymeslot, :stub_flag, :show_marketing_links)

      assert Config.show_marketing_links?()
      refute Config.enforce_legal_agreements?()
      refute Config.logo_links_to_marketing?()
    end

    test "logo_links_to_marketing? delegates to the matching callback" do
      Application.put_env(:tymeslot, :stub_flag, :logo_links_to_marketing)

      assert Config.logo_links_to_marketing?()
      refute Config.enforce_legal_agreements?()
      refute Config.show_marketing_links?()
    end

    test "registration_enabled? and password_auth_enabled? delegate to their own callbacks" do
      Application.put_env(:tymeslot, :stub_flag, :registration_enabled)

      assert Config.registration_enabled?()
      refute Config.password_auth_enabled?()
    end

    test "site_home_path returns the overlay's path, not Core's default" do
      assert Config.site_home_path() == "/stub-home"
    end
  end

  defp with_key(key, value, fun) do
    swap(key, fn -> Application.put_env(:tymeslot, key, value) end, fun)
  end

  defp without_key(key, fun) do
    swap(key, fn -> Application.delete_env(:tymeslot, key) end, fun)
  end

  defp swap(key, set, fun) do
    previous = Application.fetch_env(:tymeslot, key)
    set.()

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:tymeslot, key, value)
        :error -> Application.delete_env(:tymeslot, key)
      end
    end
  end
end
