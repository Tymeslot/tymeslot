defmodule Tymeslot.Features.DefaultAccessCheckerTest do
  @moduledoc """
  Coverage for `Tymeslot.Features.DefaultAccessChecker`, the Core
  fallback that ships with self-hosted deployments. Most features open
  unconditionally so a self-hoster never hits a paywall, but a small
  set of features (e.g. `:meeting_payments`) gate on a runtime flag —
  the feature is a self-host opt-in even though there is no
  subscription plan to enforce.

  These tests run `async: false` because they mutate
  `Application.put_env/3` on `:tymeslot`.
  """

  use ExUnit.Case, async: false
  @moduletag :infrastructure

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Features.DefaultAccessChecker

  describe "check_access/2 :meeting_payments" do
    test "returns :ok when meeting_payments_enabled is true" do
      with_config(:tymeslot, :meeting_payments_enabled, true)

      assert :ok = DefaultAccessChecker.check_access(1, :meeting_payments)
    end

    test "returns {:error, :feature_disabled} by default" do
      with_config(:tymeslot, :meeting_payments_enabled, false)

      assert {:error, :feature_disabled} =
               DefaultAccessChecker.check_access(1, :meeting_payments)
    end
  end

  describe "check_access/2 ungated features" do
    test "returns :ok for any other feature regardless of config" do
      assert :ok = DefaultAccessChecker.check_access(1, :any_other_feature)
      assert :ok = DefaultAccessChecker.check_access(1, :automations_allowed)
    end
  end
end
