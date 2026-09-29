defmodule Tymeslot.Infrastructure.ErrorTracking.RuntimeSwitchTest do
  # async: false: the tests set a process-wide environment variable and read
  # the global ErrorTracker switch.
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import Tymeslot.ConfigTestHelpers

  alias Config.Reader
  alias ErrorTracker.Error
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Test.LogCapture

  @env_var "ERROR_TRACKING_ENABLED"
  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  setup do
    previous = System.get_env(@env_var)

    on_exit(fn ->
      if previous, do: System.put_env(@env_var, previous), else: System.delete_env(@env_var)
    end)

    :ok
  end

  describe "ERROR_TRACKING_ENABLED in config/runtime.exs" do
    for value <- ["false", "0", "no", "off", " False "] do
      test "#{inspect(value)} switches error tracking off" do
        System.put_env(@env_var, unquote(value))

        assert runtime_error_tracker_config()[:enabled] == false
      end
    end

    for value <- ["true", "1", "yes", "ON"] do
      test "#{inspect(value)} switches error tracking on" do
        System.put_env(@env_var, unquote(value))

        assert runtime_error_tracker_config()[:enabled] == true
      end
    end

    test "unset leaves the compile-time default in place" do
      System.delete_env(@env_var)

      refute Keyword.has_key?(runtime_error_tracker_config(), :enabled)
    end

    test "an unrecognised value fails the boot, naming the variable" do
      System.put_env(@env_var, "flase")

      assert_raise RuntimeError, ~r/ERROR_TRACKING_ENABLED must be true or false/, fn ->
        runtime_error_tracker_config()
      end
    end
  end

  describe "with error tracking switched off" do
    setup do
      with_config(:error_tracker, enabled: false)
      :ok
    end

    test "enabled?/0 is false" do
      refute ErrorTracking.enabled?()
    end

    test "report_error/3 still logs the failure but stores nothing" do
      LogCapture.attach()

      :ok = ErrorTracking.report_error(:timeout, nil, %{meeting_id: 3})

      assert LogCapture.await_log("Handled an unexpected error").meta.meeting_id == 3
      assert Repo.all(Error) == []
    end
  end

  defp runtime_error_tracker_config do
    @runtime_exs
    |> Reader.read!(env: :test, target: :host)
    |> Keyword.get(:error_tracker, [])
  end
end
