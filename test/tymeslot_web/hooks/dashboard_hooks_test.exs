defmodule TymeslotWeb.Hooks.DashboardHooksTest do
  use ExUnit.Case, async: false
  @moduletag :utils

  import ExUnit.CaptureLog

  alias TymeslotWeb.Hooks.AuthLiveSessionHook
  alias TymeslotWeb.Hooks.ClientInfoHook
  alias TymeslotWeb.Hooks.DashboardHooks

  setup do
    original = Application.get_env(:tymeslot, :dashboard_additional_hooks)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, :dashboard_additional_hooks)
      else
        Application.put_env(:tymeslot, :dashboard_additional_hooks, original)
      end
    end)

    :ok
  end

  test "returns a configured list of hooks" do
    hooks = [
      {AuthLiveSessionHook, :ensure_authenticated},
      ClientInfoHook
    ]

    Application.put_env(:tymeslot, :dashboard_additional_hooks, hooks)

    assert DashboardHooks.dashboard_additional_hooks() == hooks
  end

  test "wraps a single hook value and logs a warning" do
    hook = {AuthLiveSessionHook, :ensure_authenticated}

    log =
      capture_log(fn ->
        Application.put_env(:tymeslot, :dashboard_additional_hooks, hook)

        assert DashboardHooks.dashboard_additional_hooks() == [hook]
      end)

    assert log =~ "Expected :dashboard_additional_hooks to be a list, received a single hook"
  end

  test "raises on a value that is not a list of hooks" do
    Application.put_env(:tymeslot, :dashboard_additional_hooks, "invalid")

    assert_raise ArgumentError, ~r/expected :dashboard_additional_hooks to be a list/, fn ->
      DashboardHooks.dashboard_additional_hooks()
    end
  end

  # These hooks are deployment gates (a legal-acceptance check, for
  # instance). An entry that cannot be run used to be skipped, which switched the
  # gate off without a trace.
  test "raises on an entry that is neither a module nor a {module, hook} tuple" do
    Application.put_env(:tymeslot, :dashboard_additional_hooks, [
      ClientInfoHook,
      {AuthLiveSessionHook, :ensure_authenticated, :extra}
    ])

    assert_raise ArgumentError, ~r/unrecognised :dashboard_additional_hooks entry/, fn ->
      DashboardHooks.dashboard_additional_hooks()
    end
  end

  test "a mount through the dashboard chain fails rather than skipping a bad entry" do
    Application.put_env(:tymeslot, :dashboard_additional_hooks, ["MyApp.Hooks.Typo"])

    socket = %Phoenix.LiveView.Socket{endpoint: TymeslotWeb.Endpoint}

    assert_raise ArgumentError, ~r/unrecognised :dashboard_additional_hooks entry/, fn ->
      DashboardHooks.on_mount(:dashboard, %{}, %{}, socket)
    end
  end

  test "a mount through the onboarding chain applies the additional gates too" do
    Application.put_env(:tymeslot, :dashboard_additional_hooks, ["MyApp.Hooks.Typo"])

    socket = %Phoenix.LiveView.Socket{endpoint: TymeslotWeb.Endpoint}

    assert_raise ArgumentError, ~r/unrecognised :dashboard_additional_hooks entry/, fn ->
      DashboardHooks.on_mount(:onboarding, %{}, %{}, socket)
    end
  end

  describe "validate_additional_hooks!/0 (run at boot)" do
    test "accepts hooks that define on_mount/4" do
      Application.put_env(:tymeslot, :dashboard_additional_hooks, [
        {AuthLiveSessionHook, :ensure_authenticated},
        ClientInfoHook
      ])

      assert :ok = DashboardHooks.validate_additional_hooks!()
    end

    test "rejects a well-formed entry naming a module that does not exist" do
      Application.put_env(:tymeslot, :dashboard_additional_hooks, [
        {MyApp.Hooks.Mispelt, :check}
      ])

      assert_raise ArgumentError, ~r/MyApp.Hooks.Mispelt, which does not define on_mount/, fn ->
        DashboardHooks.validate_additional_hooks!()
      end
    end
  end
end
