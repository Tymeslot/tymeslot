defmodule Tymeslot.MeetingPaymentsTest do
  @moduledoc """
  Covers `Tymeslot.MeetingPayments.platform_configured?/0`, the predicate the
  admin settings UI uses to decide whether the "Meeting payments" toggle is
  unlockable. A real Stripe platform secret key must be present; the
  `"sk_test_fake"` placeholder shipped in dev/test fixtures does not count.
  """

  use ExUnit.Case, async: false
  @moduletag :payments

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingPayments

  describe "platform_configured?/0" do
    test "returns false when no Stripe platform key is set" do
      with_config(:tymeslot, :stripe_secret_key, nil)
      with_config(:stripity_stripe, :api_key, nil)

      refute MeetingPayments.platform_configured?()
    end

    test "returns false when the dev/test placeholder key is set" do
      with_config(:tymeslot, :stripe_secret_key, nil)
      with_config(:stripity_stripe, :api_key, "sk_test_fake")

      refute MeetingPayments.platform_configured?()
    end

    test "returns false when the platform key is an empty string" do
      with_config(:tymeslot, :stripe_secret_key, "")
      with_config(:stripity_stripe, :api_key, nil)

      refute MeetingPayments.platform_configured?()
    end

    test "returns true when a real platform key is set on :stripity_stripe" do
      with_config(:tymeslot, :stripe_secret_key, nil)
      with_config(:stripity_stripe, :api_key, "sk_test_51Hxxxxxxxxxxxxxxxxxxxxxx")

      assert MeetingPayments.platform_configured?()
    end

    test ":tymeslot, :stripe_secret_key takes precedence over :stripity_stripe, :api_key" do
      with_config(:tymeslot, :stripe_secret_key, "rk_test_51Hxxxxxxxxxxxxxxxxxxxxxx")
      with_config(:stripity_stripe, :api_key, "sk_test_fake")

      assert MeetingPayments.platform_configured?()
    end
  end

  describe "connect_display_state/1" do
    test "maps a missing account to :not_connected" do
      assert MeetingPayments.connect_display_state(nil) == :not_connected
    end

    test "maps a soft-deleted account to :deleted" do
      account = %{deleted_at: DateTime.utc_now(), details_submitted: true}

      assert MeetingPayments.connect_display_state(account) == :deleted
    end

    test "maps an unsubmitted account to :incomplete" do
      account = %{deleted_at: nil, details_submitted: false}

      assert MeetingPayments.connect_display_state(account) == :incomplete
    end

    test "maps a submitted account with a disabled_reason to :restricted" do
      account = %{
        deleted_at: nil,
        details_submitted: true,
        disabled_reason: "requirements.past_due"
      }

      assert MeetingPayments.connect_display_state(account) == :restricted
    end

    test "maps a submitted account with charges and payouts enabled to :ready" do
      account = %{
        deleted_at: nil,
        details_submitted: true,
        disabled_reason: nil,
        charges_enabled: true,
        payouts_enabled: true
      }

      assert MeetingPayments.connect_display_state(account) == :ready
    end

    test "maps a submitted-but-not-yet-enabled account to :pending_review" do
      account = %{
        deleted_at: nil,
        details_submitted: true,
        disabled_reason: nil,
        charges_enabled: false,
        payouts_enabled: false
      }

      assert MeetingPayments.connect_display_state(account) == :pending_review
    end
  end
end
