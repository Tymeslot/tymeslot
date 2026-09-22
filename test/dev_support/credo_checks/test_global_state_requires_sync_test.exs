Code.require_file(
  "dev_support/credo_checks/test_global_state_requires_sync.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.TestGlobalStateRequiresSyncTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.TestGlobalStateRequiresSync

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags setup :set_mox_global while async: true" do
      """
      defmodule Tymeslot.Workers.SomeGlobalMoxTest do
        use Tymeslot.DataCase, async: true

        setup :set_mox_global

        test "does the thing" do
          :ok
        end
      end
      """
      |> to_source_file("test/tymeslot/workers/some_global_mox_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue(fn issue -> assert issue.trigger == "async: true" end)
    end

    test "flags a bare set_mox_global() call while async: true" do
      """
      defmodule Tymeslot.Workers.BareMoxCallTest do
        use Tymeslot.DataCase, async: true

        setup do
          set_mox_global()
          :ok
        end
      end
      """
      |> to_source_file("test/tymeslot/workers/bare_mox_call_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue()
    end

    test "flags Mox.set_mox_global/0 while async: true" do
      """
      defmodule Tymeslot.Workers.QualifiedMoxCallTest do
        use Tymeslot.DataCase, async: true

        setup do
          Mox.set_mox_global()
          :ok
        end
      end
      """
      |> to_source_file("test/tymeslot/workers/qualified_mox_call_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue()
    end

    test "flags LogCapture.attach/1 with :logger_level while async: true" do
      """
      defmodule Tymeslot.Audit.LoweredLevelTest do
        use Tymeslot.DataCase, async: true

        test "logs at debug" do
          LogCapture.attach(logger_level: :debug)
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/lowered_level_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue(fn issue -> assert issue.trigger == "async: true" end)
    end

    test "flags LogCapture.with_capture/2 with :logger_level while async: true" do
      """
      defmodule Tymeslot.Audit.LoweredLevelWithCaptureTest do
        use Tymeslot.DataCase, async: true

        test "logs at info" do
          LogCapture.with_capture([logger_level: :info], fn ->
            :ok
          end)
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/lowered_level_with_capture_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue()
    end

    test "flags refute_receive on :captured_log while async: true" do
      """
      defmodule Tymeslot.Audit.QuietPathTest do
        use Tymeslot.DataCase, async: true

        test "does not log" do
          LogCapture.attach()
          refute_receive {:captured_log, _}, 100
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/quiet_path_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue(fn issue -> assert issue.trigger == "async: true" end)
    end

    test "flags refute_received on :captured_log while async: true" do
      """
      defmodule Tymeslot.Audit.QuietReceivedTest do
        use Tymeslot.DataCase, async: true

        test "does not log" do
          LogCapture.attach()
          refute_received {:captured_log, _}
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/quiet_received_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue()
    end

    test "flags a module using the BrowserCase template while async: true" do
      """
      defmodule Tymeslot.Web.LoginFlowTest do
        use TymeslotWeb.BrowserCase, async: true
      end
      """
      |> to_source_file("test/tymeslot_web/e2e/login_flow_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue(fn issue -> assert issue.trigger == "async: true" end)
    end

    test "flags a module importing the HealthCheckTestSetup template while async: true" do
      """
      defmodule Tymeslot.Integrations.HealthCheckImportTest do
        use Tymeslot.DataCase, async: true
        import Tymeslot.Integrations.HealthCheckTestSetup

        setup :start_health_check_server
      end
      """
      |> to_source_file("test/tymeslot/integrations/health_check_import_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> assert_issue()
    end
  end

  describe "accepted cases" do
    test "accepts setup :set_mox_global when async: false" do
      """
      defmodule Tymeslot.Workers.SomeGlobalMoxTest do
        use Tymeslot.DataCase, async: false

        setup :set_mox_global
      end
      """
      |> to_source_file("test/tymeslot/workers/some_global_mox_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    test "accepts LogCapture.attach/1 with :logger_level when async: false" do
      """
      defmodule Tymeslot.Audit.LoweredLevelTest do
        use Tymeslot.DataCase, async: false

        test "logs at debug" do
          LogCapture.attach(logger_level: :debug)
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/lowered_level_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    test "accepts refute_receive on :captured_log when async: false" do
      """
      defmodule Tymeslot.Audit.QuietPathTest do
        use Tymeslot.DataCase, async: false

        test "does not log" do
          LogCapture.attach()
          refute_receive {:captured_log, _}, 100
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/quiet_path_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    test "accepts a module using the BrowserCase template when async: false" do
      """
      defmodule Tymeslot.Web.LoginFlowTest do
        use TymeslotWeb.BrowserCase, async: false
      end
      """
      |> to_source_file("test/tymeslot_web/e2e/login_flow_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    test "accepts a module importing HealthCheckTestSetup when async: false" do
      """
      defmodule Tymeslot.Integrations.HealthCheckImportTest do
        use Tymeslot.DataCase, async: false
        import Tymeslot.Integrations.HealthCheckTestSetup

        setup :start_health_check_server
      end
      """
      |> to_source_file("test/tymeslot/integrations/health_check_import_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    test "accepts a plain LogCapture.attach() asserting only presence, while async: true" do
      """
      defmodule Tymeslot.Audit.PresenceOnlyTest do
        use Tymeslot.DataCase, async: true

        test "logs the event" do
          LogCapture.attach()
          assert_receive {:captured_log, %{level: :warning}}
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/presence_only_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    test "accepts an opted-out module while async: true" do
      """
      defmodule Tymeslot.Workers.OptedOutMoxTest do
        # credo:global-state-safe — this is the only test that stubs Extension
        use Tymeslot.DataCase, async: true

        setup :set_mox_global
      end
      """
      |> to_source_file("test/tymeslot/workers/opted_out_mox_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    test "accepts a non-Test module doing the same things while async: true" do
      """
      defmodule Tymeslot.Workers.MoxHelpers do
        use Tymeslot.DataCase, async: true

        setup :set_mox_global
      end
      """
      |> to_source_file("test/tymeslot/workers/mox_helpers.ex")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    test "accepts a file under test/support/ doing the same things while async: true" do
      """
      defmodule Tymeslot.Support.GlobalMoxSetupTest do
        use Tymeslot.DataCase, async: true

        setup :set_mox_global
      end
      """
      |> to_source_file("test/support/global_mox_setup_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    # `:level` filters the capture handler, which is per-caller. Only
    # `:logger_level` lowers the node-wide primary level. This is the one
    # distinction in the check most likely to regress into flagging every
    # capture, so it is pinned here rather than left to the moduledoc.
    test "accepts LogCapture.attach/1 with :level but no :logger_level, while async: true" do
      """
      defmodule Tymeslot.Audit.FilteredLevelTest do
        use Tymeslot.DataCase, async: true

        setup do
          LogCapture.attach(level: :debug)
          :ok
        end

        test "logs" do
          assert_receive {:captured_log, _}
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/filtered_level_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end

    # The options walk is scoped to the first argument for this reason: the
    # closure passed to with_capture/2 is not a statement about the primary
    # Logger level, whatever keys happen to appear inside it.
    test "accepts a :logger_level key appearing only inside with_capture's closure" do
      """
      defmodule Tymeslot.Audit.ClosureKeyTest do
        use Tymeslot.DataCase, async: true

        test "logs" do
          LogCapture.with_capture([], fn ->
            assert %{logger_level: :warning} = build_config()
          end)
        end
      end
      """
      |> to_source_file("test/tymeslot/audit/closure_key_test.exs")
      |> run_check(TestGlobalStateRequiresSync)
      |> refute_issues()
    end
  end
end
