Code.require_file(
  "dev_support/credo_checks/mox_expect_requires_verify.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.MoxExpectRequiresVerifyTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.MoxExpectRequiresVerify

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags a bare expect/3 against a *Mock alias with no verify_on_exit!" do
      """
      defmodule Tymeslot.CalendarSyncTest do
        use Tymeslot.DataCase, async: true

        test "syncs the calendar" do
          expect(CalendarMock, :fetch, fn _ -> :ok end)
          CalendarSync.run()
        end
      end
      """
      |> to_source_file("test/tymeslot/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> assert_issue(fn issue -> assert issue.trigger == "expect" end)
    end

    test "flags Mox.expect/3 against a *Mock alias with no verify_on_exit!" do
      """
      defmodule Tymeslot.CalendarSyncTest do
        use Tymeslot.DataCase, async: true

        test "syncs the calendar" do
          Mox.expect(CalendarMock, :fetch, fn _ -> :ok end)
          CalendarSync.run()
        end
      end
      """
      |> to_source_file("test/tymeslot/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> assert_issue(fn issue -> assert issue.trigger == "expect" end)
    end
  end

  describe "accepted cases" do
    test "accepts expect/3 when the module declares setup :verify_on_exit!" do
      """
      defmodule Tymeslot.CalendarSyncTest do
        use Tymeslot.DataCase, async: true

        setup :verify_on_exit!

        test "syncs the calendar" do
          expect(CalendarMock, :fetch, fn _ -> :ok end)
          CalendarSync.run()
        end
      end
      """
      |> to_source_file("test/tymeslot/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end

    test "accepts expect/3 when verify_on_exit! is called inside a setup block" do
      """
      defmodule Tymeslot.CalendarSyncTest do
        use Tymeslot.DataCase, async: true

        setup do
          verify_on_exit!()
          :ok
        end

        test "syncs the calendar" do
          expect(CalendarMock, :fetch, fn _ -> :ok end)
          CalendarSync.run()
        end
      end
      """
      |> to_source_file("test/tymeslot/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end

    test "accepts expect/3 when the module uses a registered verifying template" do
      """
      defmodule Tymeslot.CalendarSyncTest do
        use Tymeslot.VerifyingCase, async: true

        test "syncs the calendar" do
          expect(CalendarMock, :fetch, fn _ -> :ok end)
          CalendarSync.run()
        end
      end
      """
      |> to_source_file("test/tymeslot/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify, verifying_templates: [Tymeslot.VerifyingCase])
      |> refute_issues()
    end

    test "accepts :meck.expect, which is never a Mox call" do
      """
      defmodule Tymeslot.ApprovalSweepTest do
        use Tymeslot.DataCase, async: true

        test "expires the approval" do
          :meck.expect(SomeModule, :fun, fn -> :ok end)
          ApprovalSweep.run()
        end
      end
      """
      |> to_source_file("test/tymeslot/approval_sweep_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end

    test "ignores an unverified expect/3 under test/support/" do
      """
      defmodule Tymeslot.MockHelperTest do
        def setup_mocks do
          expect(CalendarMock, :fetch, fn _ -> :ok end)
        end
      end
      """
      |> to_source_file("test/support/mock_helper_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end

    test "accepts an inline Mox.verify!() instead of verify_on_exit!" do
      """
      defmodule Tymeslot.BookingTest do
        use Tymeslot.DataCase, async: true

        test "sends a confirmation" do
          expect(Tymeslot.EmailServiceMock, :send, fn _ -> {:ok, :sent} end)
          BookingFlow.confirm(booking())
          Mox.verify!()
        end
      end
      """
      |> to_source_file("test/tymeslot/booking_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end

    test "accepts a bare verify!() call" do
      """
      defmodule Tymeslot.BookingTest do
        use Tymeslot.DataCase, async: true

        test "sends a confirmation" do
          expect(Tymeslot.EmailServiceMock, :send, fn _ -> {:ok, :sent} end)
          verify!()
        end
      end
      """
      |> to_source_file("test/tymeslot/booking_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end

    test "accepts a helper-named call in a file that never imported the helper" do
      """
      defmodule Tymeslot.BookingTest do
        use Tymeslot.DataCase, async: true

        test "books" do
          expect_http_success(:post)
        end

        defp expect_http_success(_verb), do: :ok
      end
      """
      |> to_source_file("test/tymeslot/booking_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end
  end

  # A file need not call expect/3,4 itself to own an unverified expectation:
  # the support helpers in :expect_helpers set one on their caller's behalf,
  # and Credo cannot follow the call across files.
  describe "expectations set by a support helper" do
    test "flags an imported helper call with no verify_on_exit!" do
      """
      defmodule Tymeslot.Workers.CalendarSyncTest do
        use Tymeslot.DataCase, async: true

        import Tymeslot.WorkerTestHelpers

        test "syncs" do
          expect_calendar_create_success(booking())
          CalendarSync.run()
        end
      end
      """
      |> to_source_file("test/tymeslot/workers/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> assert_issue()
    end

    test "flags an aliased helper call with no verify_on_exit!" do
      """
      defmodule Tymeslot.Workers.CalendarSyncTest do
        use Tymeslot.DataCase, async: true

        alias Tymeslot.WorkerTestHelpers

        test "syncs" do
          WorkerTestHelpers.expect_http_success(:post)
        end
      end
      """
      |> to_source_file("test/tymeslot/workers/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> assert_issue()
    end

    test "accepts an imported helper call when the file verifies" do
      """
      defmodule Tymeslot.Workers.CalendarSyncTest do
        use Tymeslot.DataCase, async: true

        import Tymeslot.WorkerTestHelpers

        setup :verify_on_exit!

        test "syncs" do
          expect_calendar_create_success(booking())
        end
      end
      """
      |> to_source_file("test/tymeslot/workers/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end

    test "accepts a call to an unlisted function of a listed helper module" do
      """
      defmodule Tymeslot.Workers.CalendarSyncTest do
        use Tymeslot.DataCase, async: true

        alias Tymeslot.WorkerTestHelpers

        test "syncs" do
          WorkerTestHelpers.build_booking()
        end
      end
      """
      |> to_source_file("test/tymeslot/workers/calendar_sync_test.exs")
      |> run_check(MoxExpectRequiresVerify)
      |> refute_issues()
    end
  end
end
