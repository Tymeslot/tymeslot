defmodule Tymeslot.MeetingPayments.Webhooks.WebhookProcessorTest do
  # Connect handlers (`account.updated`) hit the DB, so we lean on
  # DataCase's sandbox rather than `ExUnit.Case, async: true`.
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :unit

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.WebhookProcessor

  setup :verify_on_exit!

  describe "process/3" do
    test "normalises signature verification failures to :signature_failure" do
      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:error, "bad signature"}
      end)

      assert {:error, :signature_failure} =
               WebhookProcessor.process("{}", "t=1,v1=BAD", "whsec_secret")
    end

    test "accepts events older than 5 minutes (Stripe retry semantics)" do
      # Stripe retries failed deliveries for up to 72 hours, always carrying the
      # ORIGINAL `created` timestamp. A redundant age check would permanently
      # drop any event whose first delivery failed transiently — replay
      # protection lives in the signature's `t=` tolerance (300 s).
      old_created = System.os_time(:second) - 6 * 60

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok, %{"id" => "evt_OLD", "type" => "ping.event", "created" => old_created}}
      end)

      assert :ok = WebhookProcessor.process(~s({}), "t=1,v1=GOOD", "whsec_secret")
    end

    test "returns :ok and ignores events that have no registered handler" do
      now = System.os_time(:second)

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok, %{"id" => "evt_X", "type" => "ping.event", "created" => now}}
      end)

      assert :ok = WebhookProcessor.process(~s({}), "t=1,v1=GOOD", "whsec_secret")
    end

    test "dispatches to the registered handler when type is known" do
      now = System.os_time(:second)

      # A matching row must exist, otherwise `apply_account_event/2` takes its
      # `nil -> :ok` branch and the dispatch is indistinguishable from the
      # unknown-event case above.
      account =
        insert(:connect_account,
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false,
          disabled_reason: nil,
          last_account_event_at: nil
        )

      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok,
         %{
           "id" => "evt_OK",
           "type" => "account.updated",
           "created" => now,
           "data" => %{
             "object" => %{
               "id" => account.stripe_account_id,
               "created" => now,
               "charges_enabled" => true,
               "payouts_enabled" => true,
               "details_submitted" => true,
               "requirements" => %{"disabled_reason" => "requirements.past_due"}
             }
           }
         }}
      end)

      assert :ok = WebhookProcessor.process(~s({}), "t=1,v1=GOOD", "whsec_secret")

      reloaded = Repo.get!(ConnectAccountSchema, account.id)

      assert reloaded.charges_enabled
      assert reloaded.payouts_enabled
      assert reloaded.details_submitted
      assert reloaded.disabled_reason == "requirements.past_due"
      assert DateTime.to_unix(reloaded.last_account_event_at) == now
    end

    test "dispatches events with missing created timestamp to handlers" do
      # Per-handler logic uses an epoch-0 fallback for missing `created` so a
      # subsequent real event with a genuine timestamp is always considered
      # newer. The processor itself does not validate the field.
      expect(StripeAdapterMock, :construct_webhook_event, fn _payload, _sig, _secret ->
        {:ok, %{"id" => "evt_NO_CREATED", "type" => "ping.event"}}
      end)

      assert :ok = WebhookProcessor.process(~s({}), "t=1,v1=GOOD", "whsec_secret")
    end
  end
end
