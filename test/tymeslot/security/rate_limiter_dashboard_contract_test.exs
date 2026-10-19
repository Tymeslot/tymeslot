# Some of these tests drive RateLimiter checks through captures,
# invoked as fun.(...). VacuousTest cannot see application calls through
# anonymous-function invocation, so it flags them as false positives.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Tymeslot.Security.RateLimiterDashboardContractTest do
  use ExUnit.Case, async: false

  @moduletag :security

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Shared: invalid user_id validation (applies to all dashboard functions)
  # ---------------------------------------------------------------------------

  describe "invalid user_id handling" do
    @limits [
      :webhook_write,
      :webhook_test,
      :webhook_token_regen,
      :calendar_refresh,
      :integration_write,
      :integration_appearance,
      :meeting_type_write,
      :avatar_upload,
      :embed_domain_update,
      :dashboard_cancel,
      :dashboard_reschedule
    ]

    test "rejects nil user_id" do
      for name <- @limits do
        assert {:error, :invalid_user_id} = RateLimiter.check(name, nil)
      end
    end

    test "rejects zero user_id" do
      for name <- @limits do
        assert {:error, :invalid_user_id} = RateLimiter.check(name, 0)
      end
    end

    test "rejects negative user_id" do
      for name <- @limits do
        assert {:error, :invalid_user_id} = RateLimiter.check(name, -1)
      end
    end

    test "rejects non-integer user_id" do
      for name <- @limits do
        assert {:error, :invalid_user_id} = RateLimiter.check(name, "123")
        assert {:error, :invalid_user_id} = RateLimiter.check(name, 123.45)
      end
    end

    test "accepts valid positive integer user_ids" do
      for name <- @limits do
        assert :ok = RateLimiter.check(name, 1)
        assert :ok = RateLimiter.check(name, 999_999)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shared: error message format consistency
  # ---------------------------------------------------------------------------

  describe "error message format" do
    test "all new functions produce actionable error messages" do
      cases = [
        {11_901, &RateLimiter.check(:webhook_write, &1), 30, "webhook_write"},
        {11_902, &RateLimiter.check(:webhook_test, &1), 30, "webhook_test"},
        {11_903, &RateLimiter.check(:webhook_token_regen, &1), 10, "webhook_token_regen"},
        {11_904, &RateLimiter.check(:calendar_refresh, &1), 10, "calendar_refresh"},
        {11_905, &RateLimiter.check(:integration_write, &1), 30, "integration_write"},
        {11_910, &RateLimiter.check(:integration_appearance, &1), 150, "integration_appearance"},
        {11_906, &RateLimiter.check(:meeting_type_write, &1), 60, "meeting_type_write"},
        {11_907, &RateLimiter.check(:avatar_upload, &1), 20, "avatar_upload"},
        {11_908, &RateLimiter.check(:dashboard_cancel, &1), 20, "dashboard_cancel"},
        {11_909, &RateLimiter.check(:dashboard_reschedule, &1), 20, "dashboard_reschedule"}
      ]

      for {user_id, fun, limit, bucket_prefix} <- cases do
        for _i <- 1..limit, do: fun.(user_id)

        assert {:error, :rate_limited, message} = fun.(user_id),
               "#{bucket_prefix} should be rate limited after #{limit} requests"

        assert message =~ ~r/limit of \d+ .+ actions per (\d+ )?(minute|hour|day)s?/,
               "#{bucket_prefix} message format: #{message}"

        # The wait is the limiter's own `retry_after`, not the window: "try
        # again in 30 minutes" would be the window restated, and useless.
        assert message =~
                 ~r/Please try again in (a moment|1 (minute|hour|day)|\d+ (minutes|hours|days))\./,
               "#{bucket_prefix} message should say how long to wait: #{message}"
      end
    end
  end
end
