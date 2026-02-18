defmodule Tymeslot.Security.RateLimiterDashboardTest do
  use ExUnit.Case, async: false

  @moduletag :security

  import Tymeslot.RateLimiterTestHelpers

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # check_webhook_write_rate_limit/1 — 30 per 30 minutes
  # ---------------------------------------------------------------------------

  describe "check_webhook_write_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_001

      for i <- 1..30 do
        assert :ok = RateLimiter.check_webhook_write_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_002

      for _i <- 1..30 do
        assert :ok = RateLimiter.check_webhook_write_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_webhook_write_rate_limit(user_id)

      assert is_binary(message)
      assert message =~ "30"
      assert message =~ "30 minutes"
      assert message =~ "webhook write"
    end

    test "is scoped per user" do
      user_id_1 = 11_003
      user_id_2 = 11_004

      for _i <- 1..30 do
        RateLimiter.check_webhook_write_rate_limit(user_id_1)
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_webhook_write_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_webhook_write_rate_limit(user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_005

      for _i <- 1..30, do: RateLimiter.check_webhook_write_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_webhook_write_rate_limit(user_id)

      RateLimiter.clear_bucket("webhook_write:#{user_id}")

      assert :ok = RateLimiter.check_webhook_write_rate_limit(user_id)
    end

    test "multiple users operate independently" do
      test_multiple_users_operate_independently(
        [11_011, 11_012, 11_013, 11_014, 11_015],
        20,
        &RateLimiter.check_webhook_write_rate_limit/1
      )
    end
  end

  # ---------------------------------------------------------------------------
  # check_webhook_test_rate_limit/1 — 30 per 5 minutes
  # ---------------------------------------------------------------------------

  describe "check_webhook_test_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_101

      for i <- 1..30 do
        assert :ok = RateLimiter.check_webhook_test_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_102

      for _i <- 1..30 do
        assert :ok = RateLimiter.check_webhook_test_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_webhook_test_rate_limit(user_id)

      assert message =~ "30"
      assert message =~ "5 minutes"
      assert message =~ "webhook test"
    end

    test "is scoped per user" do
      user_id_1 = 11_103
      user_id_2 = 11_104

      for _i <- 1..30, do: RateLimiter.check_webhook_test_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_webhook_test_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_webhook_test_rate_limit(user_id_2)
    end
  end

  # ---------------------------------------------------------------------------
  # check_webhook_token_regen_rate_limit/1 — 10 per hour
  # ---------------------------------------------------------------------------

  describe "check_webhook_token_regen_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_201

      for i <- 1..10 do
        assert :ok = RateLimiter.check_webhook_token_regen_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_202

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_webhook_token_regen_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_webhook_token_regen_rate_limit(user_id)

      assert message =~ "10"
      assert message =~ "60 minutes"
      assert message =~ "webhook token regeneration"
    end

    test "is scoped per user" do
      user_id_1 = 11_203
      user_id_2 = 11_204

      for _i <- 1..10, do: RateLimiter.check_webhook_token_regen_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_webhook_token_regen_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_webhook_token_regen_rate_limit(user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_205

      for _i <- 1..10, do: RateLimiter.check_webhook_token_regen_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_webhook_token_regen_rate_limit(user_id)

      RateLimiter.clear_bucket("webhook_token_regen:#{user_id}")

      assert :ok = RateLimiter.check_webhook_token_regen_rate_limit(user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check_calendar_refresh_rate_limit/1 — 10 per 10 minutes
  # ---------------------------------------------------------------------------

  describe "check_calendar_refresh_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_301

      for i <- 1..10 do
        assert :ok = RateLimiter.check_calendar_refresh_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_302

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_calendar_refresh_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_calendar_refresh_rate_limit(user_id)

      assert message =~ "10"
      assert message =~ "10 minutes"
      assert message =~ "calendar refresh"
    end

    test "is scoped per user" do
      user_id_1 = 11_303
      user_id_2 = 11_304

      for _i <- 1..10, do: RateLimiter.check_calendar_refresh_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_calendar_refresh_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_calendar_refresh_rate_limit(user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_305

      for _i <- 1..10, do: RateLimiter.check_calendar_refresh_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_calendar_refresh_rate_limit(user_id)

      RateLimiter.clear_bucket("calendar_refresh:#{user_id}")

      assert :ok = RateLimiter.check_calendar_refresh_rate_limit(user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check_integration_write_rate_limit/1 — 30 per 30 minutes
  # ---------------------------------------------------------------------------

  describe "check_integration_write_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_401

      for i <- 1..30 do
        assert :ok = RateLimiter.check_integration_write_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_402

      for _i <- 1..30 do
        assert :ok = RateLimiter.check_integration_write_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_integration_write_rate_limit(user_id)

      assert message =~ "30"
      assert message =~ "30 minutes"
      assert message =~ "integration write"
    end

    test "is scoped per user" do
      user_id_1 = 11_403
      user_id_2 = 11_404

      for _i <- 1..30, do: RateLimiter.check_integration_write_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_integration_write_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_integration_write_rate_limit(user_id_2)
    end

    test "multiple users operate independently" do
      test_multiple_users_operate_independently(
        [11_411, 11_412, 11_413, 11_414, 11_415],
        20,
        &RateLimiter.check_integration_write_rate_limit/1
      )
    end
  end

  # ---------------------------------------------------------------------------
  # check_meeting_type_write_rate_limit/1 — 60 per 30 minutes
  # ---------------------------------------------------------------------------

  describe "check_meeting_type_write_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_501

      for i <- 1..60 do
        assert :ok = RateLimiter.check_meeting_type_write_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_502

      for _i <- 1..60 do
        assert :ok = RateLimiter.check_meeting_type_write_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_meeting_type_write_rate_limit(user_id)

      assert message =~ "60"
      assert message =~ "30 minutes"
      assert message =~ "meeting type write"
    end

    test "is scoped per user" do
      user_id_1 = 11_503
      user_id_2 = 11_504

      for _i <- 1..60, do: RateLimiter.check_meeting_type_write_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_meeting_type_write_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_meeting_type_write_rate_limit(user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_505

      for _i <- 1..60, do: RateLimiter.check_meeting_type_write_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_meeting_type_write_rate_limit(user_id)

      RateLimiter.clear_bucket("meeting_type_write:#{user_id}")

      assert :ok = RateLimiter.check_meeting_type_write_rate_limit(user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check_avatar_upload_rate_limit/1 — 20 per hour
  # ---------------------------------------------------------------------------

  describe "check_avatar_upload_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_601

      for i <- 1..20 do
        assert :ok = RateLimiter.check_avatar_upload_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_602

      for _i <- 1..20 do
        assert :ok = RateLimiter.check_avatar_upload_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_avatar_upload_rate_limit(user_id)

      assert message =~ "20"
      assert message =~ "60 minutes"
      assert message =~ "avatar upload"
    end

    test "is scoped per user" do
      user_id_1 = 11_603
      user_id_2 = 11_604

      for _i <- 1..20, do: RateLimiter.check_avatar_upload_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_avatar_upload_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_avatar_upload_rate_limit(user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_605

      for _i <- 1..20, do: RateLimiter.check_avatar_upload_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_avatar_upload_rate_limit(user_id)

      RateLimiter.clear_bucket("avatar_upload:#{user_id}")

      assert :ok = RateLimiter.check_avatar_upload_rate_limit(user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check_dashboard_cancel_rate_limit/1 — 20 per 10 minutes
  # ---------------------------------------------------------------------------

  describe "check_dashboard_cancel_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_701

      for i <- 1..20 do
        assert :ok = RateLimiter.check_dashboard_cancel_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_702

      for _i <- 1..20 do
        assert :ok = RateLimiter.check_dashboard_cancel_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_dashboard_cancel_rate_limit(user_id)

      assert message =~ "20"
      assert message =~ "10 minutes"
      assert message =~ "meeting cancellation"
    end

    test "is scoped per user" do
      user_id_1 = 11_703
      user_id_2 = 11_704

      for _i <- 1..20, do: RateLimiter.check_dashboard_cancel_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_dashboard_cancel_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_dashboard_cancel_rate_limit(user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_705

      for _i <- 1..20, do: RateLimiter.check_dashboard_cancel_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_dashboard_cancel_rate_limit(user_id)

      RateLimiter.clear_bucket("dashboard_cancel:#{user_id}")

      assert :ok = RateLimiter.check_dashboard_cancel_rate_limit(user_id)
    end

    test "multiple users operate independently" do
      test_multiple_users_operate_independently(
        [11_711, 11_712, 11_713, 11_714, 11_715],
        15,
        &RateLimiter.check_dashboard_cancel_rate_limit/1
      )
    end
  end

  # ---------------------------------------------------------------------------
  # check_dashboard_reschedule_rate_limit/1 — 20 per 10 minutes
  # ---------------------------------------------------------------------------

  describe "check_dashboard_reschedule_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_801

      for i <- 1..20 do
        assert :ok = RateLimiter.check_dashboard_reschedule_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_802

      for _i <- 1..20 do
        assert :ok = RateLimiter.check_dashboard_reschedule_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_dashboard_reschedule_rate_limit(user_id)

      assert message =~ "20"
      assert message =~ "10 minutes"
      assert message =~ "reschedule request"
    end

    test "is scoped per user" do
      user_id_1 = 11_803
      user_id_2 = 11_804

      for _i <- 1..20, do: RateLimiter.check_dashboard_reschedule_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_dashboard_reschedule_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_dashboard_reschedule_rate_limit(user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_805

      for _i <- 1..20, do: RateLimiter.check_dashboard_reschedule_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_dashboard_reschedule_rate_limit(user_id)

      RateLimiter.clear_bucket("dashboard_reschedule:#{user_id}")

      assert :ok = RateLimiter.check_dashboard_reschedule_rate_limit(user_id)
    end

    test "cancel and reschedule use independent buckets" do
      user_id = 11_806

      # Exhaust only the reschedule bucket
      for _i <- 1..20, do: RateLimiter.check_dashboard_reschedule_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_dashboard_reschedule_rate_limit(user_id)

      # Cancel bucket should be unaffected
      assert :ok = RateLimiter.check_dashboard_cancel_rate_limit(user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Shared: invalid user_id validation (applies to all new functions)
  # ---------------------------------------------------------------------------

  describe "invalid user_id handling" do
    @functions [
      &RateLimiter.check_webhook_write_rate_limit/1,
      &RateLimiter.check_webhook_test_rate_limit/1,
      &RateLimiter.check_webhook_token_regen_rate_limit/1,
      &RateLimiter.check_calendar_refresh_rate_limit/1,
      &RateLimiter.check_integration_write_rate_limit/1,
      &RateLimiter.check_meeting_type_write_rate_limit/1,
      &RateLimiter.check_avatar_upload_rate_limit/1,
      &RateLimiter.check_dashboard_cancel_rate_limit/1,
      &RateLimiter.check_dashboard_reschedule_rate_limit/1
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
        {11_906, &RateLimiter.check_meeting_type_write_rate_limit/1, 60, "meeting_type_write"},
        {11_907, &RateLimiter.check_avatar_upload_rate_limit/1, 20, "avatar_upload"},
        {11_908, &RateLimiter.check_dashboard_cancel_rate_limit/1, 20, "dashboard_cancel"},
        {11_909, &RateLimiter.check_dashboard_reschedule_rate_limit/1, 20, "dashboard_reschedule"}
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
