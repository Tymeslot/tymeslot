# These tests drive RateLimiter functions through captures held in @functions,
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
    @functions [
      &RateLimiter.check_webhook_write_rate_limit/1,
      &RateLimiter.check_webhook_test_rate_limit/1,
      &RateLimiter.check_webhook_token_regen_rate_limit/1,
      &RateLimiter.check_calendar_refresh_rate_limit/1,
      &RateLimiter.check_integration_write_rate_limit/1,
      &RateLimiter.check_integration_appearance_rate_limit/1,
      &RateLimiter.check_meeting_type_write_rate_limit/1,
      &RateLimiter.check_avatar_upload_rate_limit/1,
      &RateLimiter.check_dashboard_cancel_rate_limit/1,
      &RateLimiter.check_dashboard_reschedule_rate_limit/1,
      &RateLimiter.check_sync_link_write_rate_limit/1
    ]

    test "rejects nil user_id" do
      for fun <- @functions do
        assert {:error, :invalid_user_id} = fun.(nil)
      end
    end

    test "rejects zero user_id" do
      for fun <- @functions do
        assert {:error, :invalid_user_id} = fun.(0)
      end
    end

    test "rejects negative user_id" do
      for fun <- @functions do
        assert {:error, :invalid_user_id} = fun.(-1)
      end
    end

    test "rejects non-integer user_id" do
      for fun <- @functions do
        assert {:error, :invalid_user_id} = fun.("123")
        assert {:error, :invalid_user_id} = fun.(123.45)
      end
    end

    test "accepts valid positive integer user_ids" do
      for fun <- @functions do
        assert :ok = fun.(1)
        assert :ok = fun.(999_999)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shared: error message format consistency
  # ---------------------------------------------------------------------------

  describe "error message format" do
    test "all new functions produce actionable error messages" do
      cases = [
        {11_901, &RateLimiter.check_webhook_write_rate_limit/1, 30, "webhook_write"},
        {11_902, &RateLimiter.check_webhook_test_rate_limit/1, 30, "webhook_test"},
        {11_903, &RateLimiter.check_webhook_token_regen_rate_limit/1, 10, "webhook_token_regen"},
        {11_904, &RateLimiter.check_calendar_refresh_rate_limit/1, 10, "calendar_refresh"},
        {11_905, &RateLimiter.check_integration_write_rate_limit/1, 30, "integration_write"},
        {11_910, &RateLimiter.check_integration_appearance_rate_limit/1, 150,
         "integration_appearance"},
        {11_906, &RateLimiter.check_meeting_type_write_rate_limit/1, 60, "meeting_type_write"},
        {11_907, &RateLimiter.check_avatar_upload_rate_limit/1, 20, "avatar_upload"},
        {11_908, &RateLimiter.check_dashboard_cancel_rate_limit/1, 20, "dashboard_cancel"},
        {11_909, &RateLimiter.check_dashboard_reschedule_rate_limit/1, 20,
         "dashboard_reschedule"},
        {11_911, &RateLimiter.check_sync_link_write_rate_limit/1, 60, "sync_link_write"}
      ]

      for {user_id, fun, limit, bucket_prefix} <- cases do
        for _i <- 1..limit, do: fun.(user_id)

        assert {:error, :rate_limited, message} = fun.(user_id),
               "#{bucket_prefix} should be rate limited after #{limit} requests"

        assert message =~ ~r/limit of \d+ .+ actions per \d+ minutes/,
               "#{bucket_prefix} message format: #{message}"

        assert message =~ "wait",
               "#{bucket_prefix} message should suggest waiting: #{message}"
      end
    end
  end
end
