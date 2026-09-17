defmodule Tymeslot.MeetingPaymentsTest do
  @moduledoc """
  Covers the `Tymeslot.MeetingPayments` facade functions with logic of their
  own: `platform_configured?/0` (the predicate the admin settings UI uses to
  decide whether the "Meeting payments" toggle is unlockable; a real Stripe
  platform secret key must be present, and the `"sk_test_fake"` placeholder
  shipped in dev/test fixtures does not count), `connect_display_state/1`, and
  `host_currency/1`.
  """

  use Tymeslot.DataCase, async: false
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

  describe "host_currency/1" do
    test "returns the live Connect account's default currency" do
      user = insert(:user)
      insert(:connect_account, user: user, default_currency: "gbp")

      assert MeetingPayments.host_currency(user.id) == "gbp"
    end

    test "falls back to eur when the live account has no default currency" do
      user = insert(:user)
      insert(:connect_account, user: user, default_currency: nil)

      assert MeetingPayments.host_currency(user.id) == "eur"
    end

    test "falls back to eur when the live account's default currency is blank" do
      user = insert(:user)
      insert(:connect_account, user: user, default_currency: "")

      assert MeetingPayments.host_currency(user.id) == "eur"
    end

    test "ignores a soft-deleted account's currency" do
      user = insert(:user)

      insert(:connect_account,
        user: user,
        default_currency: "gbp",
        deleted_at: DateTime.utc_now(:second)
      )

      assert MeetingPayments.host_currency(user.id) == "eur"
    end

    test "falls back to eur when the host has no Connect account" do
      user = insert(:user)

      assert MeetingPayments.host_currency(user.id) == "eur"
    end

    test "falls back to eur without a user" do
      assert MeetingPayments.host_currency(nil) == "eur"
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
