Code.require_file(
  "dev_support/credo_checks/rate_limiter_boundary.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.RateLimiterBoundaryTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.RateLimiterBoundary

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "allowed files" do
    test "no issues inside connection_probe.ex" do
      """
      defmodule Tymeslot.Integrations.Shared.ConnectionProbe do
        alias Tymeslot.Security.RateLimiter

        defp check(bucket, actor), do: RateLimiter.check_connection_test_rate_limit(bucket, actor)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/shared/connection_probe.ex")
      |> run_check(RateLimiterBoundary)
      |> refute_issues()
    end

    test "no issues inside a security/ implementation module" do
      """
      defmodule Tymeslot.Security.RateLimiter do
        alias Tymeslot.Security.RateLimiter

        def check(bucket, actor), do: RateLimiter.check_connection_test_rate_limit(bucket, actor)
      end
      """
      |> to_source_file("lib/tymeslot/security/rate_limiter.ex")
      |> run_check(RateLimiterBoundary)
      |> refute_issues()
    end

    test "no issues for test files" do
      """
      defmodule Tymeslot.SomeTest do
        alias Tymeslot.Security.RateLimiter

        def call(bucket, actor), do: RateLimiter.check_connection_test_rate_limit(bucket, actor)
      end
      """
      |> to_source_file("test/tymeslot/some_test.exs")
      |> run_check(RateLimiterBoundary)
      |> refute_issues()
    end

    test "no issues for a filename matched by the :allowed param" do
      """
      defmodule Tymeslot.Some.Exception do
        alias Tymeslot.Security.RateLimiter

        def call(bucket, actor), do: RateLimiter.check_connection_test_rate_limit(bucket, actor)
      end
      """
      |> to_source_file("lib/tymeslot/some/exception.ex")
      |> run_check(RateLimiterBoundary, allowed: ["lib/tymeslot/some/exception.ex"])
      |> refute_issues()
    end
  end

  describe "allowed functions" do
    test "check_integration_write_rate_limit is not flagged (out of scope)" do
      """
      defmodule TymeslotWeb.Dashboard.VideoSettingsComponent do
        alias Tymeslot.Security.RateLimiter

        def guard(user_id), do: RateLimiter.check_integration_write_rate_limit(user_id)
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard/video_settings_component.ex")
      |> run_check(RateLimiterBoundary)
      |> refute_issues()
    end
  end

  describe "flagged calls" do
    test "check_connection_test_rate_limit called from a context module is flagged" do
      """
      defmodule Tymeslot.Integrations.Calendar do
        alias Tymeslot.Security.RateLimiter

        def check(bucket, actor), do: RateLimiter.check_connection_test_rate_limit(bucket, actor)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar.ex")
      |> run_check(RateLimiterBoundary)
      |> assert_issue(fn issue ->
        assert issue.trigger == "RateLimiter.check_connection_test_rate_limit"
      end)
    end

    test "fully qualified call is flagged" do
      """
      defmodule Tymeslot.Integrations.Calendar do
        def check(bucket, actor),
          do: Tymeslot.Security.RateLimiter.check_connection_test_rate_limit(bucket, actor)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar.ex")
      |> run_check(RateLimiterBoundary)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Tymeslot.Security.RateLimiter.check_connection_test_rate_limit"
      end)
    end
  end

  describe "no false positives for unrelated calls" do
    test "a same-named function on a different module is not flagged" do
      """
      defmodule Tymeslot.Integrations.Calendar do
        alias Tymeslot.Cache

        def check(bucket, actor), do: Cache.check_connection_test_rate_limit(bucket, actor)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar.ex")
      |> run_check(RateLimiterBoundary)
      |> refute_issues()
    end

    test "a different RateLimiter function is not flagged" do
      """
      defmodule Tymeslot.Integrations.Calendar do
        alias Tymeslot.Security.RateLimiter

        def check(bucket, scope), do: RateLimiter.check_rate_limit(bucket, scope, 1000)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar.ex")
      |> run_check(RateLimiterBoundary)
      |> refute_issues()
    end
  end
end
