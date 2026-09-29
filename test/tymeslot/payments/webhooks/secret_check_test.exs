defmodule Tymeslot.Payments.Webhooks.SecretCheckTest do
  # async: false: the admin alert implementation and the Stripe settings are
  # global application env.
  use ExUnit.Case, async: false

  @moduletag :payments
  @moduletag :webhooks

  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Payments.StripeMock
  alias Tymeslot.Payments.SubscriptionManagerMock
  alias Tymeslot.Payments.Webhooks.SecretCheck
  alias Tymeslot.Test.LogCapture

  setup :capture_admin_alerts
  setup :set_mox_global

  # A fully configured deployment: a real Stripe key, subscriptions, meeting
  # payments and both webhook secrets. Each test removes one piece.
  setup do
    setup_config(:stripity_stripe, :api_key, "stripe-key-configured")

    setup_config(:tymeslot,
      stripe_secret_key: nil,
      subscription_manager: SubscriptionManagerMock,
      meeting_payments_enabled: true,
      stripe_connect_webhook_secret: "whsec_connect"
    )

    stub(StripeMock, :webhook_secret, fn -> "whsec_platform" end)
    :ok
  end

  test "a fully configured deployment raises nothing" do
    assert SecretCheck.check() == []
    refute_receive {:send_alert, _type, _payload}
  end

  test "a missing platform secret alerts and logs an error" do
    stub(StripeMock, :webhook_secret, fn -> nil end)
    LogCapture.attach()

    assert SecretCheck.check() == ["STRIPE_WEBHOOK_SECRET"]

    assert_receive {:send_alert, :stripe_webhook_secret_missing,
                    %{env_var: "STRIPE_WEBHOOK_SECRET"}}

    assert_receive {:captured_log, %{level: :error, meta: %{env_var: "STRIPE_WEBHOOK_SECRET"}}}
  end

  test "a missing Connect secret alerts when meeting payments are on" do
    setup_config(:tymeslot, :stripe_connect_webhook_secret, "")

    assert SecretCheck.check() == ["STRIPE_CONNECT_WEBHOOK_SECRET"]

    assert_receive {:send_alert, :stripe_webhook_secret_missing,
                    %{env_var: "STRIPE_CONNECT_WEBHOOK_SECRET"}}
  end

  test "a missing Connect secret is fine while meeting payments are off" do
    setup_config(:tymeslot,
      meeting_payments_enabled: false,
      stripe_connect_webhook_secret: nil
    )

    assert SecretCheck.check() == []
    refute_receive {:send_alert, _type, _payload}
  end

  test "a missing platform secret is fine without subscriptions" do
    setup_config(:tymeslot, :subscription_manager, nil)
    stub(StripeMock, :webhook_secret, fn -> nil end)

    assert SecretCheck.check() == []
    refute_receive {:send_alert, _type, _payload}
  end

  test "nothing is checked without a real Stripe key" do
    setup_config(:stripity_stripe, :api_key, "sk_test_fake")
    stub(StripeMock, :webhook_secret, fn -> nil end)
    setup_config(:tymeslot, :stripe_connect_webhook_secret, nil)

    assert SecretCheck.check() == []
    refute_receive {:send_alert, _type, _payload}
  end
end
