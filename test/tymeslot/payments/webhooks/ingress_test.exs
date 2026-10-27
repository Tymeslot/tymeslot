defmodule Tymeslot.Payments.Webhooks.IngressTest do
  # async: false: the signing secrets, the subscription manager, the admin
  # alert sink and ErrorTracker's switch are global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :webhooks

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias ErrorTracker.Error
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.Payments.SubscriptionInvoiceSchema
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Payments.Webhooks.Ingress
  alias Tymeslot.Payments.Webhooks.StripeEventQueries
  alias Tymeslot.PaymentTestHelpers

  @platform_secret "whsec_ingress_platform"
  @connect_secret "whsec_ingress_connect"

  defmodule RecordingManager do
    @spec handle_checkout_completed(map()) :: {:ok, map()}
    def handle_checkout_completed(session) do
      send(Application.get_env(:tymeslot, :ingress_test_pid), {:checkout_completed, session})
      {:ok, %{}}
    end
  end

  defmodule TimingOutManager do
    @spec handle_checkout_completed(map()) :: {:error, term()}
    def handle_checkout_completed(_session), do: {:error, :database_timeout}
  end

  defmodule BrokenManager do
    @spec handle_checkout_completed(map()) :: no_return()
    def handle_checkout_completed(_session), do: raise("a bug for cus_secret")
  end

  defmodule ExitingManager do
    @spec handle_checkout_completed(map()) :: no_return()
    def handle_checkout_completed(_session),
      do: exit({:timeout, {GenServer, :call, [:cus_secret]}})
  end

  defmodule ThrowingManager do
    @spec handle_checkout_completed(map()) :: no_return()
    def handle_checkout_completed(_session), do: throw(:cus_secret)
  end

  defmodule TestAdminAlerts do
    @spec send_alert(atom(), map()) :: :ok
    def send_alert(event_type, payload) do
      send(Application.get_env(:tymeslot, :ingress_test_pid), {:send_alert, event_type, payload})
      :ok
    end
  end

  setup do
    with_config(:tymeslot,
      stripe_webhook_secret: @platform_secret,
      stripe_connect_webhook_secret: @connect_secret,
      subscription_manager: RecordingManager,
      admin_alerts_impl: TestAdminAlerts,
      ingress_test_pid: self()
    )

    :ok
  end

  defp deliver(endpoint, event, secret \\ nil) do
    body = Jason.encode!(event)
    secret = secret || if endpoint == :platform, do: @platform_secret, else: @connect_secret
    Ingress.process(endpoint, body, PaymentTestHelpers.generate_stripe_signature(body, secret))
  end

  defp event(type, object, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => type,
        "created" => 1_700_000_000,
        "livemode" => false,
        "data" => %{"object" => object}
      },
      extra
    )
  end

  defp checkout_completed,
    do: event("checkout.session.completed", %{"id" => "cs_ingress", "mode" => "subscription"})

  describe "verification" do
    test "an endpoint without a signing secret is not configured" do
      with_config(:tymeslot, stripe_connect_webhook_secret: "")

      capture_log(fn ->
        assert {:error, :not_configured} =
                 deliver(:connect, event("account.updated", %{"id" => "acct_1"}))
      end)
    end

    test "a payload signed with another endpoint's secret is rejected" do
      capture_log(fn ->
        assert {:error, :invalid_signature} =
                 deliver(:platform, checkout_completed(), @connect_secret)
      end)

      refute_received {:checkout_completed, _session}
    end

    test "a body altered after signing is rejected" do
      body = Jason.encode!(checkout_completed())
      signature = PaymentTestHelpers.generate_stripe_signature(body, @platform_secret)
      tampered = String.replace(body, "cs_ingress", "cs_forged")

      capture_log(fn ->
        assert {:error, :invalid_signature} = Ingress.process(:platform, tampered, signature)
        assert {:error, :invalid_signature} = Ingress.process(:platform, body, nil)
      end)

      refute_received {:checkout_completed, _session}
    end

    test "a correctly signed body that is not a JSON object is an invalid payload" do
      for body <- ["not json", ~s(["evt_in_a_list"])] do
        signature = PaymentTestHelpers.generate_stripe_signature(body, @platform_secret)

        capture_log(fn ->
          assert {:error, :invalid_payload} = Ingress.process(:platform, body, signature)
        end)
      end
    end

    test "a verified event without an id is an invalid payload" do
      capture_log(fn ->
        assert {:error, :invalid_payload} =
                 deliver(:platform, Map.delete(checkout_completed(), "id"))
      end)
    end
  end

  describe "dispatch" do
    test "a verified event reaches its handler once, and a redelivery is a duplicate" do
      event = checkout_completed()

      assert {:ok, :processed} = deliver(:platform, event)
      assert_received {:checkout_completed, %{"id" => "cs_ingress"}}

      assert {:ok, :duplicate} = deliver(:platform, event)
      refute_received {:checkout_completed, _session}
    end

    test "a handler's retryable failure releases the event, so the redelivery runs again" do
      with_config(:tymeslot, subscription_manager: TimingOutManager)
      event = checkout_completed()

      capture_log(fn -> assert {:error, :retry_later} = deliver(:platform, event) end)

      with_config(:tymeslot, subscription_manager: RecordingManager)
      assert {:ok, :processed} = deliver(:platform, event)
      assert_received {:checkout_completed, _session}
    end

    test "a handler's permanent failure is acknowledged, so a redelivery is not run" do
      with_config(:tymeslot, subscription_manager: nil)
      event = checkout_completed()

      capture_log(fn -> assert {:error, :permanent} = deliver(:platform, event) end)
      assert {:ok, :duplicate} = deliver(:platform, event)
    end

    test "an event without an object is a permanent failure" do
      event = put_in(checkout_completed(), ["data"], %{})

      capture_log(fn -> assert {:error, :permanent} = deliver(:platform, event) end)
      refute_received {:checkout_completed, _session}
    end

    test "a handler that raises is retried, and recorded with its event by exception module" do
      with_config(:error_tracker, enabled: true)
      with_config(:tymeslot, subscription_manager: BrokenManager)
      event = checkout_completed()

      capture_log(fn ->
        assert {:error, :retry_later} = deliver(:platform, event)
        assert {:error, :retry_later} = deliver(:platform, event)
      end)

      # Both attempts raised from the same site, so they are one error.
      assert [%Error{reason: "{:raised, RuntimeError}"} = error] =
               Error |> Repo.all() |> Repo.preload(:occurrences)

      assert [%{context: context} = occurrence, _second] = error.occurrences
      refute inspect(occurrence) =~ "cus_secret"
      assert context["event_id"] == event["id"]
      assert context["event_type"] == "checkout.session.completed"
    end

    test "a handler that exits or throws is retried and recorded, and the redelivery runs" do
      with_config(:error_tracker, enabled: true)

      for {manager, reason} <- [{ExitingManager, ":exited"}, {ThrowingManager, ":threw"}] do
        with_config(:tymeslot, subscription_manager: manager)
        event = checkout_completed()

        capture_log(fn -> assert {:error, :retry_later} = deliver(:platform, event) end)

        # Recorded under the event, by kind of failure, without the value it
        # carried (an exit or throw value can quote the Stripe object).
        assert [occurrence] =
                 Error
                 |> Repo.all()
                 |> Repo.preload(:occurrences)
                 |> Enum.flat_map(& &1.occurrences)
                 |> Enum.filter(&(&1.context["event_id"] == event["id"]))

        assert occurrence.context["error.reason"] == reason
        refute inspect(occurrence) =~ "cus_secret"

        with_config(:tymeslot, subscription_manager: RecordingManager)
        assert {:ok, :processed} = deliver(:platform, event)
        assert_received {:checkout_completed, _session}
      end
    end

    test "the platform endpoint keeps the processed event's payload; Connect does not" do
      platform = event("invoice.upcoming", %{"object" => "invoice"})
      connect = event("charge.succeeded", %{"id" => "ch_connect"}, %{"account" => "acct_1"})

      assert {:ok, :processed} = deliver(:platform, platform)

      capture_log(fn -> assert {:ok, :processed} = deliver(:connect, connect) end)

      assert %{payload: %{"id" => id}} =
               StripeEventQueries.get_by_stripe_id(platform["id"])

      assert id == platform["id"]
      assert %{payload: nil} = StripeEventQueries.get_by_stripe_id(connect["id"])
    end
  end

  describe "Connect events" do
    @enabled_account %{
      "charges_enabled" => true,
      "payouts_enabled" => true,
      "details_submitted" => true
    }

    defp account_event(account, object_extra, event_extra) do
      event(
        "account.updated",
        Map.merge(%{"id" => account.stripe_account_id}, object_extra),
        event_extra
      )
    end

    defp connect_account do
      insert(:connect_account,
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false,
        disabled_reason: nil,
        last_account_event_at: nil
      )
    end

    test "an event reaches its handler and updates the connected account" do
      account = connect_account()
      now = System.os_time(:second)

      event =
        account_event(
          account,
          %{
            "charges_enabled" => true,
            "payouts_enabled" => true,
            "details_submitted" => true,
            "requirements" => %{"disabled_reason" => "requirements.past_due"}
          },
          %{"created" => now}
        )

      assert {:ok, :processed} = deliver(:connect, event)

      reloaded = Repo.get!(ConnectAccountSchema, account.id)
      assert reloaded.charges_enabled
      assert reloaded.payouts_enabled
      assert reloaded.details_submitted
      assert reloaded.disabled_reason == "requirements.past_due"
      assert DateTime.to_unix(reloaded.last_account_event_at) == now
    end

    # Stripe retries a failed delivery for up to 72 hours, always carrying the
    # original `created`; an age check would drop an event whose first delivery
    # failed transiently. Replay protection is the signature's timestamp
    # tolerance.
    test "an event older than five minutes is still processed" do
      account = connect_account()
      old = System.os_time(:second) - 6 * 60

      event = account_event(account, @enabled_account, %{"created" => old})

      assert {:ok, :processed} = deliver(:connect, event)
      assert Repo.get!(ConnectAccountSchema, account.id).charges_enabled
    end

    test "an event without a created timestamp is dispatched, ordered as the oldest" do
      account = connect_account()

      event =
        account
        |> account_event(@enabled_account, %{})
        |> Map.delete("created")

      assert {:ok, :processed} = deliver(:connect, event)

      reloaded = Repo.get!(ConnectAccountSchema, account.id)
      assert reloaded.charges_enabled
      assert DateTime.to_unix(reloaded.last_account_event_at) == 0
    end

    test "a failed account update is retried rather than acknowledged" do
      account = connect_account()

      event =
        account_event(account, %{"charges_enabled" => "not-a-boolean"}, %{
          "created" => System.os_time(:second)
        })

      capture_log(fn -> assert {:error, :retry_later} = deliver(:connect, event) end)

      # Released, so Stripe's redelivery is taken up again.
      assert IdempotencyCache.reserve(event["id"]) == {:ok, :reserved}
      refute Repo.get!(ConnectAccountSchema, account.id).charges_enabled
    end

    test "a handler's :invalid_event is a permanent failure, so Stripe stops redelivering" do
      event = event("account.updated", %{})

      capture_log(fn -> assert {:error, :permanent} = deliver(:connect, event) end)
      assert IdempotencyCache.reserve(event["id"]) == {:ok, :already_processed}
    end
  end

  describe "invoice events" do
    # The registry, not the handler, decides which events reach it: a type
    # missing there is answered as unhandled and the invoice never updates.
    for {event_type, status} <- [
          {"invoice.voided", :void},
          {"invoice.marked_uncollectible", :uncollectible}
        ] do
      test "a delivered #{event_type} updates the captured invoice's status" do
        invoice_id = "in_ingress_#{unquote(status)}"

        assert {:ok, :processed} =
                 deliver(
                   :platform,
                   event("invoice.finalized", %{"id" => invoice_id, "status" => "open"})
                 )

        assert {:ok, :processed} =
                 deliver(
                   :platform,
                   event(unquote(event_type), %{
                     "id" => invoice_id,
                     "status" => unquote(to_string(status))
                   })
                 )

        assert Repo.get_by!(SubscriptionInvoiceSchema, stripe_invoice_id: invoice_id).status ==
                 unquote(status)

        refute_received {:send_alert, :unhandled_webhook, _payload}
      end
    end
  end

  describe "unregistered event types" do
    test "the platform endpoint alerts an admin, without the object's details" do
      object = %{
        "id" => "obj_123",
        "object" => "charge",
        "metadata" => %{"email" => "sensitive@example.com"}
      }

      event = event("charge.unknown", object)

      logs = capture_log(fn -> assert {:ok, :processed} = deliver(:platform, event) end)
      refute logs =~ "sensitive"

      assert_receive {:send_alert, :unhandled_webhook, payload}

      assert Map.take(payload, [:event_id, :event_type, :object_id, :object_type]) == %{
               event_id: event["id"],
               event_type: "charge.unknown",
               object_id: "obj_123",
               object_type: "charge"
             }

      refute Map.has_key?(payload, :object)
    end

    test "a deliberately ignored platform type is acknowledged without an alert" do
      assert {:ok, :processed} =
               deliver(:platform, event("application_fee.created", %{"id" => "fee_1"}))

      refute_received {:send_alert, _type, _payload}
    end

    test "the echo of a customer deleted with its account is acknowledged without an alert" do
      customer = %{"id" => "cus_123", "object" => "customer", "deleted" => true}

      assert {:ok, :processed} = deliver(:platform, event("customer.deleted", customer))

      refute_received {:send_alert, _type, _payload}
    end

    test "the Connect endpoint acknowledges an unregistered type without an alert" do
      capture_log(fn ->
        assert {:ok, :processed} = deliver(:connect, event("charge.succeeded", %{"id" => "ch_1"}))
      end)

      refute_received {:send_alert, _type, _payload}
    end
  end
end
