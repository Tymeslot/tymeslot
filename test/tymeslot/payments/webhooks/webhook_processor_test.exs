defmodule Tymeslot.Payments.Webhooks.WebhookProcessorTest do
  use ExUnit.Case, async: false
  @moduletag :payments

  import Mox

  alias Tymeslot.Payments.Webhooks.WebhookProcessor

  setup :set_mox_from_context
  setup :verify_on_exit!

  defmodule TestAdminAlerts do
    @spec send_alert(atom(), map(), keyword()) :: :ok
    def send_alert(event_type, payload, _opts) do
      pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)
      send(pid, {:send_alert, event_type, payload})
      :ok
    end
  end

  describe "process_event/1 unhandled events" do
    test "sends sanitized alert payloads for unhandled events" do
      original_alerts = Application.get_env(:tymeslot, :admin_alerts_impl)
      original_pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)

      Application.put_env(:tymeslot, :admin_alerts_impl, TestAdminAlerts)
      Application.put_env(:tymeslot, :admin_alerts_test_pid, self())

      on_exit(fn ->
        Application.put_env(:tymeslot, :admin_alerts_impl, original_alerts)
        Application.put_env(:tymeslot, :admin_alerts_test_pid, original_pid)
      end)

      event = %{
        "id" => "evt_999",
        "type" => "charge.unknown",
        "created" => 1_700_000_000,
        "livemode" => false,
        "data" => %{
          "object" => %{
            "id" => "obj_123",
            "object" => "charge",
            "metadata" => %{"email" => "sensitive@example.com"}
          }
        }
      }

      assert {:ok, :unhandled_event} = WebhookProcessor.process_event(event)

      assert_receive {:send_alert, :unhandled_webhook, payload}
      assert payload.event_id == "evt_999"
      assert payload.event_type == "charge.unknown"
      assert payload.object_id == "obj_123"
      assert payload.object_type == "charge"
      refute Map.has_key?(payload, :event)
      refute Map.has_key?(payload, :object)
    end
  end

  describe "process_event/1 retry behavior" do
    test "returns retry_later for Stripe outages" do
      original_provider = Application.get_env(:tymeslot, :stripe_provider)
      Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)

      on_exit(fn ->
        Application.put_env(:tymeslot, :stripe_provider, original_provider)
      end)

      # The handler expects a map with "customer" key or atom :customer
      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:error, %{message: "Stripe API is down"}}
      end)

      object = %{
        "id" => "dp_outage",
        "charge" => "ch_outage",
        "amount" => 1000,
        "status" => "needs_response",
        "reason" => "fraudulent"
      }

      event = %{
        "id" => "evt_outage",
        "type" => "charge.dispute.created",
        "data" => %{
          "object" => object
        }
      }

      assert {:error, :retry_later, _error_reason} = WebhookProcessor.process_event(event)
    end
  end
end
