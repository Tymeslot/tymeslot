defmodule Tymeslot.Infrastructure.ConfigTest do
  # async: false — these tests swap individual global config keys, which every
  # concurrently running test that reads `Config.*` would otherwise see.
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Config

  describe "flags" do
    test "registration_enabled? reads its key and defaults to on" do
      refute with_key(:registration_enabled, false, &Config.registration_enabled?/0)
      assert with_key(:registration_enabled, true, &Config.registration_enabled?/0)
      assert without_key(:registration_enabled, &Config.registration_enabled?/0)
    end

    test "password_auth_enabled? reads its key and defaults to on" do
      refute with_key(:password_auth_enabled, false, &Config.password_auth_enabled?/0)
      assert with_key(:password_auth_enabled, true, &Config.password_auth_enabled?/0)
      assert without_key(:password_auth_enabled, &Config.password_auth_enabled?/0)
    end

    test "enforce_legal_agreements? reads its key and defaults to off" do
      assert with_key(:enforce_legal_agreements, true, &Config.enforce_legal_agreements?/0)
      refute with_key(:enforce_legal_agreements, false, &Config.enforce_legal_agreements?/0)
      refute without_key(:enforce_legal_agreements, &Config.enforce_legal_agreements?/0)
    end

    test "logo_links_to_marketing? reads its key and defaults to off" do
      assert with_key(:logo_links_to_marketing, true, &Config.logo_links_to_marketing?/0)
      refute with_key(:logo_links_to_marketing, false, &Config.logo_links_to_marketing?/0)
      refute without_key(:logo_links_to_marketing, &Config.logo_links_to_marketing?/0)
    end

    test "site_home_path reads its key and defaults to the dashboard" do
      assert with_key(:site_home_path, "/elsewhere", &Config.site_home_path/0) == "/elsewhere"
      assert without_key(:site_home_path, &Config.site_home_path/0) == "/dashboard"
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
