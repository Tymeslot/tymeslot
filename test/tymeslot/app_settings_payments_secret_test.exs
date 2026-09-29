defmodule Tymeslot.AppSettingsPaymentsSecretTest do
  @moduledoc """
  Switching meeting payments on in the admin settings makes the Stripe
  Connect webhook secret required. When it is missing, the operator hears
  about it at the moment of the switch, not only at the next boot.
  """

  # async: false: the settings, the Stripe key and the admin alert
  # implementation are global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.AppSettingsEnvHelpers
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.AppSettings
  alias Tymeslot.Test.LogCapture

  setup :restore_app_settings_env
  setup :capture_admin_alerts

  setup do
    setup_config(:stripity_stripe, :api_key, "stripe-key-configured")
    setup_config(:tymeslot, stripe_secret_key: nil, meeting_payments_enabled: false)
    :ok
  end

  test "enabling meeting payments without the Connect secret alerts and logs" do
    setup_config(:tymeslot, :stripe_connect_webhook_secret, nil)
    LogCapture.attach()

    assert {:ok, _settings} = AppSettings.update(%{meeting_payments_enabled: true})

    assert_receive {:send_alert, :stripe_webhook_secret_missing,
                    %{env_var: "STRIPE_CONNECT_WEBHOOK_SECRET"}}

    assert_receive {:captured_log,
                    %{level: :error, meta: %{env_var: "STRIPE_CONNECT_WEBHOOK_SECRET"}}}
  end

  test "enabling meeting payments with the Connect secret set raises nothing" do
    setup_config(:tymeslot, :stripe_connect_webhook_secret, "whsec_connect")

    assert {:ok, _settings} = AppSettings.update(%{meeting_payments_enabled: true})

    refute_receive {:send_alert, :stripe_webhook_secret_missing, _payload}
  end

  test "a save that leaves meeting payments alone does not re-raise the alert" do
    setup_config(:tymeslot,
      meeting_payments_enabled: true,
      stripe_connect_webhook_secret: nil
    )

    assert {:ok, _settings} = AppSettings.update(%{email_brand_name: "Acme"})

    refute_receive {:send_alert, :stripe_webhook_secret_missing, _payload}
  end
end
