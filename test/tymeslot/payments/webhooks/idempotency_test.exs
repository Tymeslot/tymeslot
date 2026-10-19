defmodule Tymeslot.Payments.Webhooks.IdempotencyTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :webhooks

  import ExUnit.CaptureLog

  alias Tymeslot.Payments.Webhooks.Idempotency
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Payments.Webhooks.StripeEventQueries

  setup do
    %{event_id: "evt_idem_#{System.unique_integer([:positive])}"}
  end

  defp processed?(event_id),
    do: IdempotencyCache.reserve(event_id) == {:ok, :already_processed}

  defp released?(event_id) do
    # A released reservation can be taken again straight away; a held one
    # answers `:in_progress` and a settled one `:already_processed`.
    match?({:ok, :reserved}, IdempotencyCache.reserve(event_id))
  end

  describe "with_idempotency/4" do
    test "a successful handler is marked processed, with the payload stored", %{event_id: id} do
      payload = %{"id" => id, "type" => "invoice.paid"}

      assert {:ok, :processed} =
               Idempotency.with_idempotency(id, "invoice.paid", fn -> {:ok, :done} end,
                 payload: payload
               )

      assert processed?(id)
      assert StripeEventQueries.get_by_stripe_id(id).payload == payload
    end

    test "a bare :ok counts as success", %{event_id: id} do
      assert {:ok, :processed} = Idempotency.with_idempotency(id, "t", fn -> :ok end)
      assert processed?(id)
    end

    test "a retryable failure releases the reservation", %{event_id: id} do
      assert {:error, :retry_later} =
               Idempotency.with_idempotency(id, "t", fn -> {:error, :retry_later, "later"} end)

      assert released?(id)
    end

    test "a permanent failure is marked processed, so Stripe stops redelivering", %{event_id: id} do
      assert {:error, :permanent} =
               Idempotency.with_idempotency(id, "t", fn ->
                 {:error, :permanent, :invalid_timestamp}
               end)

      assert processed?(id)
    end

    # A shape the handler contract does not allow could hide a lost payment
    # event, so it is retried (never acknowledged) and logged as an error.
    for {label, result} <- [
          {"a bare two-element error", {:error, :invalid_timestamp}},
          {"a bare retry_later atom", {:error, :retry_later}},
          {"an error with another atom and a message", {:error, :bad, "message"}},
          {"an arbitrary tuple", {:weird, :shape, :entirely, 4}}
        ] do
      test "#{label} is retried and logged as an error", %{event_id: id} do
        log =
          capture_log([level: :error], fn ->
            assert {:error, :retry_later} =
                     Idempotency.with_idempotency(id, "t", fn -> unquote(Macro.escape(result)) end)
          end)

        assert log =~ "broke its result contract"
        assert released?(id)
      end
    end

    test "a raising handler releases the reservation and re-raises", %{event_id: id} do
      assert_raise RuntimeError, "handler blew up", fn ->
        Idempotency.with_idempotency(id, "t", fn -> raise "handler blew up" end)
      end

      assert released?(id)
    end

    test "an exiting handler releases the reservation and re-exits", %{event_id: id} do
      assert catch_exit(Idempotency.with_idempotency(id, "t", fn -> exit(:boom) end)) == :boom
      assert released?(id)
    end

    test "a processed event is not run again", %{event_id: id} do
      assert {:ok, :processed} = Idempotency.with_idempotency(id, "t", fn -> :ok end)

      assert {:ok, :duplicate} =
               Idempotency.with_idempotency(id, "t", fn -> flunk("handler ran twice") end)
    end

    test "an event still in flight asks for a retry without running the handler",
         %{event_id: id} do
      assert {:ok, :reserved} = IdempotencyCache.reserve(id)

      assert {:error, :retry_later} =
               Idempotency.with_idempotency(id, "t", fn -> flunk("ran while in flight") end)
    end
  end
end
