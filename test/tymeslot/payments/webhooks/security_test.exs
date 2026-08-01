defmodule Tymeslot.Payments.Webhooks.SecurityTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  alias Tymeslot.Payments.Webhooks.Security.{DevelopmentMode, SignatureVerifier}
  import Tymeslot.ConfigTestHelpers
  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "DevelopmentMode" do
    test "verify_if_allowed/1 returns error when not allowed" do
      with_config(:tymeslot, skip_webhook_verification: false)
      assert {:error, :not_allowed} = DevelopmentMode.verify_if_allowed("{}")
    end

    test "verify_if_allowed/1 parses JSON when allowed" do
      with_config(:tymeslot,
        skip_webhook_verification: true,
        environment: :test
      )

      assert {:ok, %{"id" => "evt_123"}} =
               DevelopmentMode.verify_if_allowed(~S({"id": "evt_123"}))
    end

    test "verify_if_allowed/1 returns error on invalid JSON" do
      with_config(:tymeslot,
        skip_webhook_verification: true,
        environment: :test
      )

      assert {:error, %{reason: :invalid_json}} = DevelopmentMode.verify_if_allowed("invalid")
    end
  end

  describe "SignatureVerifier" do
    setup do
      setup_config(:tymeslot, stripe_provider: Tymeslot.Payments.StripeMock)
      :ok
    end

    test "verify/2 returns error when secret is missing" do
      expect(Tymeslot.Payments.StripeMock, :webhook_secret, fn -> nil end)

      assert {:error, %{reason: :missing_webhook_secret}} =
               SignatureVerifier.verify("body", "sig")
    end

    test "verify/2 returns error on invalid signature" do
      expect(Tymeslot.Payments.StripeMock, :webhook_secret, fn -> "secret" end)

      expect(Tymeslot.Payments.StripeMock, :construct_webhook_event, fn "body", "sig", "secret" ->
        {:error, :invalid_signature}
      end)

      assert {:error, %{reason: :invalid_signature}} = SignatureVerifier.verify("body", "sig")
    end

    test "verify/2 succeeds and returns event" do
      expect(Tymeslot.Payments.StripeMock, :webhook_secret, fn -> "secret" end)

      # Use a map - normalize_event only normalizes structs, so maps pass through unchanged
      event = %{
        id: "evt_123",
        data: %{
          object: %{id: "obj_123", amount: 1000}
        }
      }

      expect(Tymeslot.Payments.StripeMock, :construct_webhook_event, fn "body", "sig", "secret" ->
        {:ok, event}
      end)

      assert {:ok, verified_event} = SignatureVerifier.verify("body", "sig")
      assert verified_event.id == "evt_123"
      assert verified_event.data.object.id == "obj_123"
      assert verified_event.data.object.amount == 1000
    end
  end
end
