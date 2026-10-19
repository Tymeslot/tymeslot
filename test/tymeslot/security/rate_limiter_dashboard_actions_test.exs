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
  # check(:meeting_type_write, _) — 60 per 30 minutes
  # ---------------------------------------------------------------------------

  describe "check(:meeting_type_write, _)" do
    test "blocks requests exceeding the limit" do
      user_id = 11_502

      for _i <- 1..60 do
        assert :ok = RateLimiter.check(:meeting_type_write, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:meeting_type_write, user_id)

      assert message =~ "60"
      assert message =~ "30 minutes"
      assert message =~ "meeting type write"
    end

    test "is scoped per user" do
      user_id_1 = 11_503
      user_id_2 = 11_504

      for _i <- 1..60, do: RateLimiter.check(:meeting_type_write, user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:meeting_type_write, user_id_1)

      assert :ok = RateLimiter.check(:meeting_type_write, user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_505

      for _i <- 1..60, do: RateLimiter.check(:meeting_type_write, user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:meeting_type_write, user_id)

      RateLimiter.clear_bucket("meeting_type_write:#{user_id}")

      assert :ok = RateLimiter.check(:meeting_type_write, user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check(:meeting_type_autosave, _) — 600 per 30 minutes
  # ---------------------------------------------------------------------------

  describe "check(:meeting_type_autosave, _)" do
    test "is far more permissive than the manual write limit" do
      user_id = 11_551

      # Comfortably past the 60-write manual limit without tripping.
      for _i <- 1..120 do
        assert :ok = RateLimiter.check(:meeting_type_autosave, user_id)
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_552

      for _i <- 1..600, do: RateLimiter.check(:meeting_type_autosave, user_id)

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:meeting_type_autosave, user_id)

      assert message =~ "600"
      assert message =~ "30 minutes"
      assert message =~ "meeting type autosave"
    end

    test "is scoped per user" do
      user_id_1 = 11_553
      user_id_2 = 11_554

      for _i <- 1..600, do: RateLimiter.check(:meeting_type_autosave, user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:meeting_type_autosave, user_id_1)

      assert :ok = RateLimiter.check(:meeting_type_autosave, user_id_2)
    end
  end

  # ---------------------------------------------------------------------------
  # check(:avatar_upload, _) — 20 per hour
  # ---------------------------------------------------------------------------

  describe "check(:avatar_upload, _)" do
    test "blocks requests exceeding the limit" do
      user_id = 11_602

      for _i <- 1..20 do
        assert :ok = RateLimiter.check(:avatar_upload, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:avatar_upload, user_id)

      assert message =~ "20"
      assert message =~ "per hour"
      assert message =~ "avatar upload"
    end

    test "is scoped per user" do
      user_id_1 = 11_603
      user_id_2 = 11_604

      for _i <- 1..20, do: RateLimiter.check(:avatar_upload, user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:avatar_upload, user_id_1)

      assert :ok = RateLimiter.check(:avatar_upload, user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_605

      for _i <- 1..20, do: RateLimiter.check(:avatar_upload, user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:avatar_upload, user_id)

      RateLimiter.clear_bucket("avatar_upload:#{user_id}")

      assert :ok = RateLimiter.check(:avatar_upload, user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check(:embed_domain_update, _) — 10 per hour
  # ---------------------------------------------------------------------------

  describe "check(:embed_domain_update, _)" do
    test "blocks requests exceeding the limit" do
      user_id = 11_652

      for _i <- 1..10 do
        assert :ok = RateLimiter.check(:embed_domain_update, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:embed_domain_update, user_id)

      assert message =~ "10"
      assert message =~ "per hour"
      assert message =~ "embed domain update"
    end

    test "is scoped per user" do
      for _i <- 1..10, do: RateLimiter.check(:embed_domain_update, 11_653)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:embed_domain_update, 11_653)

      assert :ok = RateLimiter.check(:embed_domain_update, 11_654)
    end

    test "counts against the embed_domain_update bucket" do
      user_id = 11_655

      for _i <- 1..10 do
        RateLimiter.check_bucket("embed_domain_update:#{user_id}",
          limit: 10,
          window_ms: 3_600_000,
          operation: "test"
        )
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:embed_domain_update, user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check(:dashboard_cancel, _) — 20 per 10 minutes
  # ---------------------------------------------------------------------------

  describe "check(:dashboard_cancel, _)" do
    test "blocks requests exceeding the limit" do
      user_id = 11_702

      for _i <- 1..20 do
        assert :ok = RateLimiter.check(:dashboard_cancel, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:dashboard_cancel, user_id)

      assert message =~ "20"
      assert message =~ "10 minutes"
      assert message =~ "meeting cancellation"
    end

    test "is scoped per user" do
      user_id_1 = 11_703
      user_id_2 = 11_704

      for _i <- 1..20, do: RateLimiter.check(:dashboard_cancel, user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:dashboard_cancel, user_id_1)

      assert :ok = RateLimiter.check(:dashboard_cancel, user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_705

      for _i <- 1..20, do: RateLimiter.check(:dashboard_cancel, user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:dashboard_cancel, user_id)

      RateLimiter.clear_bucket("dashboard_cancel:#{user_id}")

      assert :ok = RateLimiter.check(:dashboard_cancel, user_id)
    end

    test "multiple users operate independently" do
      assert test_multiple_users_operate_independently(
               [11_711, 11_712, 11_713, 11_714, 11_715],
               15,
               &RateLimiter.check(:dashboard_cancel, &1)
             ) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # check(:dashboard_add_guests, _) — 20 per 10 minutes
  # ---------------------------------------------------------------------------

  describe "check(:dashboard_add_guests, _)" do
    test "blocks requests exceeding the limit, per user" do
      user_id = 11_870
      other_user_id = 11_871

      for _i <- 1..20 do
        assert :ok = RateLimiter.check(:dashboard_add_guests, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:dashboard_add_guests, user_id)

      assert message =~ "guest invitation"
      assert :ok = RateLimiter.check(:dashboard_add_guests, other_user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check(:dashboard_quick_add_meeting, _) — 20 per 10 minutes
  # ---------------------------------------------------------------------------

  describe "check(:dashboard_quick_add_meeting, _)" do
    test "blocks requests exceeding the limit" do
      user_id = 11_880

      for _i <- 1..20 do
        assert :ok = RateLimiter.check(:dashboard_quick_add_meeting, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:dashboard_quick_add_meeting, user_id)

      assert message =~ "20"
      assert message =~ "10 minutes"
      assert message =~ "quick add meeting"
    end

    test "is scoped per user" do
      for _i <- 1..20, do: RateLimiter.check(:dashboard_quick_add_meeting, 11_881)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:dashboard_quick_add_meeting, 11_881)

      assert :ok = RateLimiter.check(:dashboard_quick_add_meeting, 11_882)
    end

    test "resets after clearing bucket" do
      user_id = 11_883

      for _i <- 1..20, do: RateLimiter.check(:dashboard_quick_add_meeting, user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:dashboard_quick_add_meeting, user_id)

      RateLimiter.clear_bucket("dashboard_quick_add_meeting:#{user_id}")

      assert :ok = RateLimiter.check(:dashboard_quick_add_meeting, user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # check(:dashboard_reschedule, _) — 20 per 10 minutes
  # ---------------------------------------------------------------------------

  describe "check(:dashboard_reschedule, _)" do
    test "blocks requests exceeding the limit" do
      user_id = 11_802

      for _i <- 1..20 do
        assert :ok = RateLimiter.check(:dashboard_reschedule, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:dashboard_reschedule, user_id)

      assert message =~ "20"
      assert message =~ "10 minutes"
      assert message =~ "reschedule request"
    end

    test "is scoped per user" do
      user_id_1 = 11_803
      user_id_2 = 11_804

      for _i <- 1..20, do: RateLimiter.check(:dashboard_reschedule, user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:dashboard_reschedule, user_id_1)

      assert :ok = RateLimiter.check(:dashboard_reschedule, user_id_2)
    end

    test "resets after clearing bucket" do
      user_id = 11_805

      for _i <- 1..20, do: RateLimiter.check(:dashboard_reschedule, user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:dashboard_reschedule, user_id)

      RateLimiter.clear_bucket("dashboard_reschedule:#{user_id}")

      assert :ok = RateLimiter.check(:dashboard_reschedule, user_id)
    end

    test "cancel and reschedule use independent buckets" do
      user_id = 11_806

      # Exhaust only the reschedule bucket
      for _i <- 1..20, do: RateLimiter.check(:dashboard_reschedule, user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:dashboard_reschedule, user_id)

      # Cancel bucket should be unaffected
      assert :ok = RateLimiter.check(:dashboard_cancel, user_id)
    end
  end
end
