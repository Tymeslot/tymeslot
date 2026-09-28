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

  test "a handler that raises is recorded by exception module, with the event it was processing" do
    expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
      raise "stripe client bug for cus_secret"
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

    assert [%Error{reason: "{:raised, RuntimeError}"} = error] =
             Error |> Repo.all() |> Repo.preload(:occurrences)

    assert [%{context: context} = occurrence] = error.occurrences
    refute inspect(occurrence) =~ "cus_secret"
    assert context["event_id"] == "evt_handler_raise"
    assert context["event_type"] == "charge.dispute.created"
  end

  test "an exception raised outside a handler is recorded by exception module alone" do
    # An object that is not a map: validating it, before any handler runs,
    # raises a BadMapError whose message quotes it.
    event = %{
      "id" => "evt_outer_raise",
      "type" => "payment_method.attached",
      "data" => %{"object" => "cus_secret owner@example.com"}
    }

    capture_log(fn ->
      assert {:error, %{reason: :exception}, nil} = WebhookProcessor.process_event(event)
    end)

    assert [%Error{reason: "{:raised, BadMapError}"} = error] =
             Error |> Repo.all() |> Repo.preload(:occurrences)

    assert [%{context: context} = occurrence] = error.occurrences
    refute inspect(error) =~ "cus_secret"
    refute inspect(occurrence) =~ "cus_secret"
    assert context["event_id"] == "evt_outer_raise"
  end
end
