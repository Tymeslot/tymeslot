defmodule Tymeslot.FeaturesTest do
  @moduledoc """
  Coverage for `Tymeslot.Features.check_access/2`, the single
  swap-point between Core's open defaults and SaaS's subscription
  gating. A regression here either silently grants paid features
  (leaking value) or silently denies them during a checker outage
  (looks like a paywall). Either direction of failure is user-hostile.

  The checker module is resolved per call via `Application.get_env/3`,
  so the tests swap `:feature_access_checker` in and out via
  `ConfigTestHelpers.with_config/3` — async: false so one test's
  checker can't leak into another.
  """

  use ExUnit.Case, async: false
  @moduletag :infrastructure

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Features

  # ---- Stub checker modules ----
  #
  # One named module per observable branch. Swapped into the
  # application config per test via `with_config/3`. Defining them as
  # top-level modules in the test file (rather than generated on the
  # fly per test) keeps the stubs deterministic across VM restarts.

  defmodule OkChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    @spec check_access(integer(), atom()) :: :ok
    def check_access(_user_id, _feature), do: :ok
  end

  defmodule InsufficientPlanChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    @spec check_access(integer(), atom()) :: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: {:error, :insufficient_plan}
  end

  defmodule GenericErrorChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    @spec check_access(integer(), atom()) :: {:error, atom()}
    def check_access(_user_id, _feature), do: {:error, :db_timeout}
  end

  defmodule StripeRequiredChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    @spec check_access(integer(), atom()) :: {:error, :stripe_required}
    def check_access(_user_id, _feature), do: {:error, :stripe_required}
  end

  defmodule FeatureDisabledChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    @spec check_access(integer(), atom()) :: {:error, :feature_disabled}
    def check_access(_user_id, _feature), do: {:error, :feature_disabled}
  end

  defmodule ProRequiredChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    @spec check_access(integer(), atom()) :: {:error, :pro_required}
    def check_access(_user_id, _feature), do: {:error, :pro_required}
  end

  defmodule BogusReturnChecker do
    @moduledoc false
    # Intentionally does not implement CheckerBehaviour — returns an
    # out-of-spec value to exercise the fallback path in Features.check_access/2.
    @spec check_access(integer(), atom()) :: atom()
    def check_access(_user_id, _feature), do: :yolo
  end

  defmodule RaisingChecker do
    @moduledoc false
    # Intentionally does not implement CheckerBehaviour — raises to
    # exercise the rescue path in Features.check_access/2.
    @spec check_access(integer(), atom()) :: no_return()
    def check_access(_user_id, _feature), do: raise("checker infrastructure gone")
  end

  describe "check_access/2 with the default checker" do
    test "returns :ok when DefaultAccessChecker is configured" do
      # `DefaultAccessChecker` opens everything — a self-hoster with
      # no SaaS overlay must never hit a paywall.
      with_config(:tymeslot, :feature_access_checker, Tymeslot.Features.DefaultAccessChecker)

      assert :ok = Features.check_access(1, :any_feature)
    end
  end

  describe "check_access/2 with a configured checker" do
    test "passes :ok through verbatim" do
      with_config(:tymeslot, :feature_access_checker, OkChecker)

      assert :ok = Features.check_access(42, :automations)
    end

    test "passes {:error, :insufficient_plan} through verbatim" do
      # Caller must be able to distinguish a legitimate plan rejection
      # from an infrastructure hiccup so the UI can render an upgrade
      # CTA in the first case and a transient-error toast in the
      # second. Collapsing both would render "upgrade your plan" on
      # every DB outage.
      with_config(:tymeslot, :feature_access_checker, InsufficientPlanChecker)

      assert {:error, :insufficient_plan} = Features.check_access(42, :automations)
    end

    test "collapses a generic {:error, reason} into :feature_access_checker_failed" do
      with_config(:tymeslot, :feature_access_checker, GenericErrorChecker)

      assert {:error, :feature_access_checker_failed} =
               Features.check_access(42, :automations)
    end

    test "collapses an unexpected return value into :feature_access_checker_failed" do
      # A refactor could accidentally return a raw atom or boolean.
      # The unknown shape must not be mistaken for :ok.
      with_config(:tymeslot, :feature_access_checker, BogusReturnChecker)

      assert {:error, :feature_access_checker_failed} =
               Features.check_access(42, :automations)
    end

    test "a raise in the checker rescues into :feature_access_checker_failed" do
      with_config(:tymeslot, :feature_access_checker, RaisingChecker)

      assert {:error, :feature_access_checker_failed} =
               Features.check_access(42, :automations)
    end
  end

  describe "check_access/2 runtime toggle" do
    test "swapping the checker between calls switches behaviour on the next call, not mid-call" do
      # Models a mid-process config change — SaaS enabling a new
      # subscription checker after warmup. The next invocation must
      # see the new checker; an in-flight call must not be disrupted.
      with_config(:tymeslot, :feature_access_checker, OkChecker)
      assert :ok = Features.check_access(1, :any)

      with_config(:tymeslot, :feature_access_checker, InsufficientPlanChecker)
      assert {:error, :insufficient_plan} = Features.check_access(1, :any)

      with_config(:tymeslot, :feature_access_checker, RaisingChecker)
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

  describe "meeting_payments_allowed?/1" do
    # This is the single authority the dashboard init hook, the
    # integrations hub, the payments controller and the meeting-type
    # form all route through, so exercising every branch here covers
    # all four call sites' behaviour through the gate.

    test "allows when the checker returns :ok" do
      with_config(:tymeslot, :feature_access_checker, OkChecker)

      assert Features.meeting_payments_allowed?(42)
    end

    test "allows when the checker returns {:error, :stripe_required}" do
      # The plan includes the feature; the host just hasn't connected a
      # charges-enabled Stripe account yet. Settings must stay reachable
      # so they can connect one — this is the deny-to-allow flip that
      # makes this gate different from a plain :ok check.
      with_config(:tymeslot, :feature_access_checker, StripeRequiredChecker)

      assert Features.meeting_payments_allowed?(42)
    end

    test "denies when the checker returns {:error, :insufficient_plan}" do
      with_config(:tymeslot, :feature_access_checker, InsufficientPlanChecker)

      refute Features.meeting_payments_allowed?(42)
    end

    test "denies when the checker returns {:error, :feature_disabled}" do
      with_config(:tymeslot, :feature_access_checker, FeatureDisabledChecker)

      refute Features.meeting_payments_allowed?(42)
    end

    test "denies when the checker returns {:error, :pro_required}" do
      with_config(:tymeslot, :feature_access_checker, ProRequiredChecker)

      refute Features.meeting_payments_allowed?(42)
    end

    test "denies when the checker fails (generic error collapsed to :feature_access_checker_failed)" do
      with_config(:tymeslot, :feature_access_checker, GenericErrorChecker)

      refute Features.meeting_payments_allowed?(42)
    end

    test "denies when the checker raises" do
      with_config(:tymeslot, :feature_access_checker, RaisingChecker)

      refute Features.meeting_payments_allowed?(42)
    end
  end
end
