defmodule Tymeslot.Infrastructure.CrashReporterTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  import Tymeslot.AdminAlertsCaptureHelpers

  alias ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.CrashReporter
  alias Tymeslot.Security.RateLimiter

  setup :capture_admin_alerts

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
      assert payload.stacktrace =~ "Foo.bar/1"
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
      RateLimiter.clear_bucket("crash_reporter:alerts")
      RateLimiter.clear_bucket("crash_reporter:throttle_notice")

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

    test "throttle notice is logged exactly once across multiple denials in the same window" do
      # Exhaust the main bucket.
      assert CrashReporter.within_rate_limit?()
      assert CrashReporter.within_rate_limit?()
      assert CrashReporter.within_rate_limit?()

      # Three denials in the same window — the warning must appear exactly once.
      log =
        CaptureLog.capture_log(fn ->
          refute CrashReporter.within_rate_limit?()
          refute CrashReporter.within_rate_limit?()
          refute CrashReporter.within_rate_limit?()
        end)

      occurrences =
        log
        |> String.split("suppressing further crash alerts")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1,
             "Expected throttle notice exactly once, got #{occurrences} occurrences in log:\n#{log}"
    end
  end

  describe "attach/0 integration" do
    setup do
      :ok = CrashReporter.attach()
      on_exit(&CrashReporter.detach/0)
      :ok
    end

    test "attach/0 installs the handler and detach/0 removes it" do
      assert {:ok, config} = :logger.get_handler_config(:tymeslot_crash_reporter)
      assert config.module == CrashReporter

      assert :ok = CrashReporter.detach()

      assert :logger.get_handler_config(:tymeslot_crash_reporter) ==
               {:error, {:not_found, :tymeslot_crash_reporter}}

      # attach/0 is idempotent, so restoring it for on_exit/1 is safe.
      assert :ok = CrashReporter.attach()
    end

    # The crash travels through the :logger handler attach/0 installed, so the
    # production code under test is invoked by the runtime, not by this body.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a genuinely crashing supervised task raises an unhandled_crash alert" do
      CaptureLog.capture_log(fn ->
        Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
          raise "integration boom"
        end)

        assert_receive {:send_alert, :unhandled_crash, payload}, 2_000
        assert payload.kind == :error
        assert payload.reason_message =~ "integration boom"
      end)
    end
  end

  describe "loop prevention" do
    defmodule RaisingAdminAlerts do
      @spec send_alert(atom(), map()) :: no_return()
      def send_alert(_type, _payload) do
        send(Application.get_env(:tymeslot, :admin_alerts_test_pid), :reporter_invoked)
        raise "reporter blew up"
      end
    end

    defmodule ExitingAdminAlerts do
      @spec send_alert(atom(), map()) :: no_return()
      def send_alert(_type, _payload) do
        send(Application.get_env(:tymeslot, :admin_alerts_test_pid), :reporter_invoked)
        exit(:reporter_blew_up)
      end
    end

    setup do
      # The handler must be live for re-entry to be possible at all — without it,
      # a crash in the alert path cannot loop, so the test would prove nothing.
      :ok = CrashReporter.attach()
      on_exit(&CrashReporter.detach/0)
      :ok
    end

    # The crash travels through the :logger handler attach/0 installed, so the
    # production code under test is invoked by the runtime, not by this body.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a real crash whose alert path fails does not re-enter the handler" do
      Application.put_env(:tymeslot, :admin_alerts_impl, RaisingAdminAlerts)

      CaptureLog.capture_log(fn ->
        # A genuine process crash flows through the attached :logger handler.
        Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn -> raise "boom" end)

        # The handler offloads and the (raising) reporter is invoked once...
        assert_receive :reporter_invoked, 2_000
        # ...and the failed alert path produces no new handled crash, so the
        # reporter is never invoked again — no loop.
        refute_receive :reporter_invoked, 300
      end)

      # The handler survived (was not removed by repeated failures).
      assert {:ok, _config} = :logger.get_handler_config(:tymeslot_crash_reporter)
    end

    # The crash travels through the :logger handler attach/0 installed, so the
    # production code under test is invoked by the runtime, not by this body.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "a real crash whose alert path exits does not re-enter the handler" do
      Application.put_env(:tymeslot, :admin_alerts_impl, ExitingAdminAlerts)

      CaptureLog.capture_log(fn ->
        # A genuine process crash flows through the attached :logger handler.
        Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn -> raise "boom" end)

        # The handler offloads and the (exiting) reporter is invoked once...
        assert_receive :reporter_invoked, 2_000
        # ...and the exit is caught by the task body, not propagated as a new
        # crash event, so the reporter is never invoked again — no loop.
        refute_receive :reporter_invoked, 300
      end)

      # The handler survived (was not removed by repeated failures).
      assert {:ok, _config} = :logger.get_handler_config(:tymeslot_crash_reporter)
    end
  end
end
