defmodule Tymeslot.Payments.Webhooks.WebhookProcessorErrorTrackingTest do
  # async: false: ErrorTracker's `enabled` switch and the Stripe provider are
  # global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :webhooks

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.Payments.Webhooks.WebhookProcessor

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    with_config(:error_tracker, enabled: true)
    with_config(:tymeslot, stripe_provider: Tymeslot.Payments.StripeMock)
    :ok
  end

  test "a handler that raises is recorded with the event it was processing" do
    expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
      raise "stripe client bug"
    end)

    event = %{
      "id" => "evt_handler_raise",
      "type" => "charge.dispute.created",
      "data" => %{
        "object" => %{
          "id" => "dp_raise",
          "charge" => "ch_raise",
          "amount" => 1000,
          "status" => "needs_response",
          "reason" => "fraudulent"
        }
      }
    }

    capture_log(fn ->
      assert {:error, %{reason: :handler_exception}, nil} = WebhookProcessor.process_event(event)
    end)

    assert [%Error{kind: "Elixir.RuntimeError", reason: "stripe client bug"} = error] =
             Error |> Repo.all() |> Repo.preload(:occurrences)

    assert [%{context: context}] = error.occurrences
    assert context["event_id"] == "evt_handler_raise"
    assert context["event_type"] == "charge.dispute.created"
  end
end
