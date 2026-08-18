defmodule Tymeslot.Security.RateLimiterDashboardActionsTest do
  use ExUnit.Case, async: false

  @moduletag :security

  import Tymeslot.RateLimiterTestHelpers

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # check_meeting_type_write_rate_limit/1 — 60 per 30 minutes
  # ---------------------------------------------------------------------------

  describe "check_meeting_type_write_rate_limit/1" do
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
  # check_meeting_type_autosave_rate_limit/1 — 600 per 30 minutes
  # ---------------------------------------------------------------------------

  describe "check_meeting_type_autosave_rate_limit/1" do
    test "is far more permissive than the manual write limit" do
      user_id = 11_551

      # Comfortably past the 60-write manual limit without tripping.
      for _i <- 1..120 do
        assert :ok = RateLimiter.check_meeting_type_autosave_rate_limit(user_id)
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_552

      for _i <- 1..600, do: RateLimiter.check_meeting_type_autosave_rate_limit(user_id)

      assert {:error, :rate_limited, message} =
               RateLimiter.check_meeting_type_autosave_rate_limit(user_id)

      assert message =~ "600"
      assert message =~ "30 minutes"
      assert message =~ "meeting type autosave"
    end

    test "is scoped per user" do
      user_id_1 = 11_553
      user_id_2 = 11_554

      for _i <- 1..600, do: RateLimiter.check_meeting_type_autosave_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_meeting_type_autosave_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_meeting_type_autosave_rate_limit(user_id_2)
    end
  end

  # ---------------------------------------------------------------------------
  # check_avatar_upload_rate_limit/1 — 20 per hour
  # ---------------------------------------------------------------------------

  describe "check_avatar_upload_rate_limit/1" do
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
      assert test_multiple_users_operate_independently(
               [11_711, 11_712, 11_713, 11_714, 11_715],
               15,
               &RateLimiter.check_dashboard_cancel_rate_limit/1
             ) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # check_dashboard_reschedule_rate_limit/1 — 20 per 10 minutes
  # ---------------------------------------------------------------------------

  describe "check_dashboard_reschedule_rate_limit/1" do
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
end
