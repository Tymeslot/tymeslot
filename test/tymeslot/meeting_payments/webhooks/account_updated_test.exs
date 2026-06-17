defmodule Tymeslot.MeetingPayments.Webhooks.AccountUpdatedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.Webhooks.AccountUpdated

  # Stripe's account object carries a `created` field that is the
  # account-creation time — a constant across every account.updated event.
  # The event envelope carries its own `created` (the event emission time),
  # which is the value ordering must key off. Tests therefore keep the object
  # `created` fixed and vary only the envelope `created`.
  @account_created 1_600_000_000

  describe "handle/1" do
    test "applies the latest account snapshot to a known connect_account" do
      user = insert(:user)

      ca =
        insert(:connect_account,
          user: user,
          stripe_account_id: "acct_LIVE",
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false
        )

      event =
        account_event("acct_LIVE", System.os_time(:second),
          charges_enabled: true,
          payouts_enabled: true,
          details_submitted: true
        )

      assert :ok = AccountUpdated.handle(event)

      reloaded = ConnectAccountQueries.by_stripe_account_id("acct_LIVE")
      assert reloaded.id == ca.id
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
      assert reloaded.details_submitted == true
      assert reloaded.last_account_event_at
    end

    test "applies successive events that share the account object's created timestamp" do
      # Regression: ordering must use the event-envelope `created`, not the
      # account object's `created`. Both events below share the same object
      # `created` (the account-creation time); only the envelope `created`
      # advances. Keying off the object `created` would drop the second event
      # as `:eq` and the capability change would never land.
      user = insert(:user)

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_SHARED_CREATED",
        charges_enabled: false,
        payouts_enabled: false
      )

      first_emitted = System.os_time(:second) - 120
      second_emitted = first_emitted + 60

      assert :ok =
               AccountUpdated.handle(
                 account_event("acct_SHARED_CREATED", first_emitted,
                   charges_enabled: false,
                   payouts_enabled: false
                 )
               )

      assert :ok =
               AccountUpdated.handle(
                 account_event("acct_SHARED_CREATED", second_emitted,
                   charges_enabled: true,
                   payouts_enabled: true
                 )
               )

      reloaded = ConnectAccountQueries.by_stripe_account_id("acct_SHARED_CREATED")
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
    end

    test "ignores out-of-order events older than the stored last_account_event_at" do
      user = insert(:user)
      stored_event_at = DateTime.from_unix!(System.os_time(:second))

      _ca =
        insert(:connect_account,
          user: user,
          stripe_account_id: "acct_OUT_OF_ORDER",
          charges_enabled: true,
          payouts_enabled: true,
          last_account_event_at: stored_event_at
        )

      stale_emitted = DateTime.to_unix(stored_event_at) - 60

      event =
        account_event("acct_OUT_OF_ORDER", stale_emitted,
          charges_enabled: false,
          payouts_enabled: false
        )

      assert :ok = AccountUpdated.handle(event)

      reloaded = ConnectAccountQueries.by_stripe_account_id("acct_OUT_OF_ORDER")
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
    end

    test "returns :ok when no connect_account matches the stripe_account_id" do
      event = account_event("acct_GHOST", System.os_time(:second), charges_enabled: true)

      assert :ok = AccountUpdated.handle(event)
    end

    test "a real event with an older-but-genuine timestamp is accepted after a missing-created event" do
      user = insert(:user)

      _ca =
        insert(:connect_account,
          user: user,
          stripe_account_id: "acct_EPOCH_FALLBACK",
          charges_enabled: false,
          payouts_enabled: false
        )

      # First event: the envelope has no `created` field — ordering falls back
      # to epoch 0.
      missing_created_event =
        "acct_EPOCH_FALLBACK"
        |> account_event(System.os_time(:second),
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false
        )
        |> Map.delete("created")

      assert :ok = AccountUpdated.handle(missing_created_event)

      # Subsequent real event with a genuine (but older-than-now) envelope
      # timestamp must NOT be rejected as stale because epoch 0 is always older.
      real_emitted = System.os_time(:second) - 3600

      real_event =
        account_event("acct_EPOCH_FALLBACK", real_emitted,
          charges_enabled: true,
          payouts_enabled: true,
          details_submitted: true
        )

      assert :ok = AccountUpdated.handle(real_event)

      reloaded = ConnectAccountQueries.by_stripe_account_id("acct_EPOCH_FALLBACK")
      assert reloaded.charges_enabled == true
    end
  end

  # Build a realistic account.updated envelope: the top-level `created` is the
  # event emission time (`emitted_at`); the nested account object's `created`
  # is the fixed account-creation time.
  defp account_event(account_id, emitted_at, object_attrs) do
    object =
      Map.merge(
        %{
          "id" => account_id,
          "created" => @account_created,
          "details_submitted" => false,
          "requirements" => %{"disabled_reason" => nil}
        },
        stringify_keys(object_attrs)
      )

    %{
      "id" => "evt_#{account_id}_#{emitted_at}",
      "type" => "account.updated",
      "created" => emitted_at,
      "data" => %{"object" => object}
    }
  end

  defp stringify_keys(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
