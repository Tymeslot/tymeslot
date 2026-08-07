defmodule Tymeslot.Security.RateLimiterDashboardIntegrationsTest do
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
      assert test_multiple_users_operate_independently(
               [11_011, 11_012, 11_013, 11_014, 11_015],
               20,
               &RateLimiter.check_webhook_write_rate_limit/1
             ) == :ok
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
      assert test_multiple_users_operate_independently(
               [11_411, 11_412, 11_413, 11_414, 11_415],
               20,
               &RateLimiter.check_integration_write_rate_limit/1
             ) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # check_integration_appearance_rate_limit/1 — 150 per 30 minutes
  # ---------------------------------------------------------------------------

  describe "check_integration_appearance_rate_limit/1" do
    test "allows requests within the limit" do
      user_id = 11_421

      for i <- 1..150 do
        assert :ok = RateLimiter.check_integration_appearance_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding the limit" do
      user_id = 11_422

      for _i <- 1..150 do
        assert :ok = RateLimiter.check_integration_appearance_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_integration_appearance_rate_limit(user_id)

      assert message =~ "150"
      assert message =~ "30 minutes"
      assert message =~ "integration appearance"
    end

    test "is scoped per user" do
      user_id_1 = 11_423
      user_id_2 = 11_424

      for _i <- 1..150, do: RateLimiter.check_integration_appearance_rate_limit(user_id_1)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_integration_appearance_rate_limit(user_id_1)

      assert :ok = RateLimiter.check_integration_appearance_rate_limit(user_id_2)
    end

    test "draws on a separate budget from the shared integration write bucket" do
      # The point of the split: exhausting the connection-write budget must not
      # stop someone recolouring a calendar, and vice versa.
      user_id = 11_425

      for _i <- 1..30, do: RateLimiter.check_integration_write_rate_limit(user_id)

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_integration_write_rate_limit(user_id)

      assert :ok = RateLimiter.check_integration_appearance_rate_limit(user_id)
    end
  end
end
