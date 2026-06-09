defmodule Tymeslot.Infrastructure.CrashReporterTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CrashReporter

  defmodule TestAdminAlerts do
    @spec send_alert(atom(), map()) :: :ok
    def send_alert(event_type, payload) do
      pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)
      send(pid, {:send_alert, event_type, payload})
      :ok
    end
  end

  setup do
    original_impl = Application.get_env(:tymeslot, :admin_alerts_impl)
    original_pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)

    Application.put_env(:tymeslot, :admin_alerts_impl, TestAdminAlerts)
    Application.put_env(:tymeslot, :admin_alerts_test_pid, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :admin_alerts_impl, original_impl)

      if original_pid do
        Application.put_env(:tymeslot, :admin_alerts_test_pid, original_pid)
      else
        Application.delete_env(:tymeslot, :admin_alerts_test_pid)
      end
    end)

    :ok
  end

  defp crash_event(crash_reason) do
    %{level: :error, msg: {:string, "crash"}, meta: %{crash_reason: crash_reason}}
  end

  describe "reportable?/2" do
    test "exceptions not in the ignore list are reportable" do
      assert CrashReporter.reportable?(:error, %RuntimeError{message: "boom"})
    end

    test "ignored (4xx) exceptions are not reportable" do
      refute CrashReporter.reportable?(:error, %Ecto.NoResultsError{message: "none"})
    end

    test "normal exits are not reportable" do
      refute CrashReporter.reportable?(:exit, :normal)
      refute CrashReporter.reportable?(:exit, :shutdown)
      refute CrashReporter.reportable?(:exit, {:shutdown, :boom})
    end

    test "abnormal exits are reportable" do
      assert CrashReporter.reportable?(:exit, :boom)
    end

    test "throws are reportable" do
      assert CrashReporter.reportable?(:throw, :some_value)
    end
  end

  describe "log/2 classification" do
    test "an exception crash reports kind :error with the reason" do
      stack = [{Foo, :bar, 1, []}]
      CrashReporter.log(crash_event({%RuntimeError{message: "boom"}, stack}), %{})

      assert_receive {:send_alert, :unhandled_crash, payload}, 1_000
      assert payload.kind == :error
      assert payload.reason_message =~ "boom"
      assert is_binary(payload.stacktrace)
    end

    test "a throw crash reports kind :throw" do
      CrashReporter.log(crash_event({{:nocatch, :thrown}, []}), %{})
      assert_receive {:send_alert, :unhandled_crash, payload}, 1_000
      assert payload.kind == :throw
    end

    test "an abnormal exit reports kind :exit" do
      CrashReporter.log(crash_event({:boom, []}), %{})
      assert_receive {:send_alert, :unhandled_crash, payload}, 1_000
      assert payload.kind == :exit
    end

    test "a normal exit does not report" do
      CrashReporter.log(crash_event({:shutdown, []}), %{})
      refute_receive {:send_alert, :unhandled_crash, _payload}, 200
    end

    test "an ignored (4xx) exception does not report" do
      CrashReporter.log(crash_event({%Ecto.NoResultsError{message: "none"}, []}), %{})
      refute_receive {:send_alert, :unhandled_crash, _payload}, 200
    end

    test "an event without crash_reason does not report" do
      assert CrashReporter.log(%{level: :error, msg: {:string, "plain"}, meta: %{}}, %{}) == :ok
      refute_receive {:send_alert, :unhandled_crash, _payload}, 200
    end
  end

  describe "within_rate_limit?/0" do
    setup do
      original_max = Application.get_env(:tymeslot, :crash_reporter_rate_limit_max)
      Application.put_env(:tymeslot, :crash_reporter_rate_limit_max, 3)
      Tymeslot.Security.RateLimiter.clear_bucket("crash_reporter:alerts")
      Tymeslot.Security.RateLimiter.clear_bucket("crash_reporter:throttle_notice")

      on_exit(fn ->
        if original_max do
          Application.put_env(:tymeslot, :crash_reporter_rate_limit_max, original_max)
        else
          Application.delete_env(:tymeslot, :crash_reporter_rate_limit_max)
        end
      end)

      :ok
    end

    test "allows up to the configured max, then denies within the window" do
      assert CrashReporter.within_rate_limit?()
      assert CrashReporter.within_rate_limit?()
      assert CrashReporter.within_rate_limit?()
      refute CrashReporter.within_rate_limit?()
    end
  end

  describe "attach/0 integration" do
    setup do
      :ok = CrashReporter.attach()
      on_exit(&CrashReporter.detach/0)
      :ok
    end

    test "installs a :logger handler" do
      assert {:ok, _config} = :logger.get_handler_config(:tymeslot_crash_reporter)
    end

    test "a genuinely crashing supervised task raises an unhandled_crash alert" do
      ExUnit.CaptureLog.capture_log(fn ->
        Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
          raise "integration boom"
        end)

        assert_receive {:send_alert, :unhandled_crash, payload}, 2_000
        assert payload.kind == :error
        assert payload.reason_message =~ "integration boom"
      end)
    end
  end
end
