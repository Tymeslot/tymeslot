defmodule Tymeslot.Payments.Webhooks.WebhookProcessorTest do
  use ExUnit.Case, async: false
  @moduletag :payments

  import ExUnit.CaptureLog
  import Mox

  alias Tymeslot.Payments.Webhooks.WebhookProcessor

  setup :set_mox_from_context
  setup :verify_on_exit!

  defmodule TestAdminAlerts do
    @spec send_alert(atom(), map()) :: :ok
    def send_alert(event_type, payload) do
      pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)
      send(pid, {:send_alert, event_type, payload})
      :ok
    end
  end

  defmodule CrashingClock do
    def utc_now do
      if pid = Application.get_env(:tymeslot, :crashing_clock_test_pid) do
        send(pid, {:task_pid, self()})
      end

      raise "simulated recorder failure"
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

  describe "process_event/1 runtime isolation" do
    # Regression test for Task 94: the background recorder for unhandled Stripe
    # events must run under Tymeslot.TaskSupervisor so that a crash inside the
    # recorder cannot propagate to (or be silently swallowed by) the webhook
    # handler process.
    test "unhandled event still returns {:ok, :unhandled_event} when the async recorder crashes" do
      original_alerts = Application.get_env(:tymeslot, :admin_alerts_impl)
      original_clock = Application.get_env(:tymeslot, :clock)

      Application.put_env(:tymeslot, :admin_alerts_impl, TestAdminAlerts)
      Application.put_env(:tymeslot, :admin_alerts_test_pid, self())
      Application.put_env(:tymeslot, :clock, CrashingClock)
      Application.put_env(:tymeslot, :crashing_clock_test_pid, self())

      on_exit(fn ->
        if original_alerts do
          Application.put_env(:tymeslot, :admin_alerts_impl, original_alerts)
        else
          Application.delete_env(:tymeslot, :admin_alerts_impl)
        end

        Application.delete_env(:tymeslot, :admin_alerts_test_pid)
        Application.delete_env(:tymeslot, :crashing_clock_test_pid)

        if original_clock do
          Application.put_env(:tymeslot, :clock, original_clock)
        else
          Application.delete_env(:tymeslot, :clock)
        end
      end)

      event = %{
        "id" => "evt_rti_webhook",
        "type" => "charge.unknown",
        "created" => 1_700_000_000,
        "livemode" => false,
        "data" => %{
          "object" => %{
            "id" => "obj_rti",
            "object" => "charge",
            "metadata" => %{}
          }
        }
      }

      log =
        capture_log(fn ->
          # The outer handler must succeed even though the supervised recorder
          # will raise in a separate process.
          assert {:ok, :unhandled_event} = WebhookProcessor.process_event(event)

          # Receive the task pid sent from inside the supervised task body, then
          # monitor it. The :DOWN message arrives after full process termination —
          # which is after the crash report has been emitted into the logger handler.
          assert_receive {:task_pid, task_pid}, 500
          ref = Process.monitor(task_pid)
          assert_receive {:DOWN, ^ref, :process, _, _}, 500
        end)

      assert log =~ "simulated recorder failure"
    end
  end
end
