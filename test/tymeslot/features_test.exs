defmodule Tymeslot.FeaturesTest do
  @moduledoc """
  Coverage for `Tymeslot.Features.check_access/2`, the single
  swap-point between Core's open defaults and SaaS's subscription
  gating. A regression here either silently grants paid features
  (leaking value) or silently denies them during a checker outage
  (looks like a paywall). Either direction of failure is user-hostile.

  The checker module is resolved per call via `Application.get_env/3`,
  so the tests swap `:feature_access_checker` in and out — async: false
  so one test's checker can't leak into another.
  """

  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Features

  # ---- Stub checker modules ----
  #
  # One named module per observable branch. Swapped into the
  # application config per test via `Application.put_env/3` and
  # restored in the `on_exit` below. Defining them as top-level
  # modules in the test file (rather than generated on the fly per
  # test) keeps the stubs deterministic across VM restarts.

  defmodule OkChecker do
    @moduledoc false
    @spec check_access(integer(), atom()) :: :ok
    def check_access(_user_id, _feature), do: :ok
  end

  defmodule InsufficientPlanChecker do
    @moduledoc false
    @spec check_access(integer(), atom()) :: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: {:error, :insufficient_plan}
  end

  defmodule GenericErrorChecker do
    @moduledoc false
    @spec check_access(integer(), atom()) :: {:error, atom()}
    def check_access(_user_id, _feature), do: {:error, :db_timeout}
  end

  defmodule BogusReturnChecker do
    @moduledoc false
    @spec check_access(integer(), atom()) :: atom()
    def check_access(_user_id, _feature), do: :yolo
  end

  defmodule RaisingChecker do
    @moduledoc false
    @spec check_access(integer(), atom()) :: no_return()
    def check_access(_user_id, _feature), do: raise("checker infrastructure gone")
  end

  setup do
    original = Application.get_env(:tymeslot, :feature_access_checker)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, :feature_access_checker)
      else
        Application.put_env(:tymeslot, :feature_access_checker, original)
      end
    end)

    :ok
  end

  describe "check_access/2 with the default checker" do
    test "returns :ok when no explicit checker is configured — Core standalone default" do
      # `Application.get_env/3`'s default arm is `DefaultAccessChecker`
      # which opens everything. A self-hoster with no SaaS overlay
      # must never hit a paywall.
      Application.delete_env(:tymeslot, :feature_access_checker)

      assert :ok = Features.check_access(1, :any_feature)
    end
  end

  describe "check_access/2 with a configured checker" do
    test "passes :ok through verbatim" do
      Application.put_env(:tymeslot, :feature_access_checker, OkChecker)

      assert :ok = Features.check_access(42, :automations)
    end

    test "passes {:error, :insufficient_plan} through verbatim" do
      # Caller must be able to distinguish a legitimate plan rejection
      # from an infrastructure hiccup so the UI can render an upgrade
      # CTA in the first case and a transient-error toast in the
      # second. Collapsing both would render "upgrade your plan" on
      # every DB outage.
      Application.put_env(:tymeslot, :feature_access_checker, InsufficientPlanChecker)

      assert {:error, :insufficient_plan} = Features.check_access(42, :automations)
    end

    test "collapses a generic {:error, reason} into :feature_access_checker_failed" do
      Application.put_env(:tymeslot, :feature_access_checker, GenericErrorChecker)

      assert {:error, :feature_access_checker_failed} =
               Features.check_access(42, :automations)
    end

    test "collapses an unexpected return value into :feature_access_checker_failed" do
      # A refactor could accidentally return a raw atom or boolean.
      # The unknown shape must not be mistaken for :ok.
      Application.put_env(:tymeslot, :feature_access_checker, BogusReturnChecker)

      assert {:error, :feature_access_checker_failed} =
               Features.check_access(42, :automations)
    end

    test "a raise in the checker rescues into :feature_access_checker_failed" do
      Application.put_env(:tymeslot, :feature_access_checker, RaisingChecker)

      assert {:error, :feature_access_checker_failed} =
               Features.check_access(42, :automations)
    end
  end

  describe "check_access/2 runtime toggle" do
    test "swapping the checker between calls switches behaviour on the next call, not mid-call" do
      # Models a mid-process config change — SaaS enabling a new
      # subscription checker after warmup. The next invocation must
      # see the new checker; an in-flight call must not be disrupted.
      Application.put_env(:tymeslot, :feature_access_checker, OkChecker)
      assert :ok = Features.check_access(1, :any)

      Application.put_env(:tymeslot, :feature_access_checker, InsufficientPlanChecker)
      assert {:error, :insufficient_plan} = Features.check_access(1, :any)

      Application.put_env(:tymeslot, :feature_access_checker, RaisingChecker)
      assert {:error, :feature_access_checker_failed} = Features.check_access(1, :any)
    end
  end

  describe "check_access/2 invalid inputs" do
    test "returns the safe error for non-integer user_id" do
      assert {:error, :feature_access_checker_failed} = Features.check_access("1", :any)
    end

    test "returns the safe error for non-atom feature" do
      assert {:error, :feature_access_checker_failed} = Features.check_access(1, "any")
    end
  end
end
