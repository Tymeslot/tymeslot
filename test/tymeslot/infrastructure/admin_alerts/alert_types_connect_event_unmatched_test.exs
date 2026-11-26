defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypesConnectEventUnmatchedTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  describe "the alert for a Connect event acknowledged without a match" do
    test ":connect_event_unmatched names the event, the account, the intent and the charge" do
      metadata = %{
        event_id: "evt_LOST",
        event_type: "charge.refunded",
        stripe_account_id: "acct_HOST",
        payment_intent_id: "pi_LOST",
        charge_id: "ch_LOST",
        reason_message: "permission_error"
      }

      msg = AlertTypes.format_message(:connect_event_unmatched, metadata)

      for part <- Map.values(metadata), do: assert(msg =~ part)
    end

    test ":connect_event_unmatched dedups per account" do
      key = &AlertTypes.dedup_key(:connect_event_unmatched, %{stripe_account_id: &1})

      assert key.("acct_A") == key.("acct_A")
      refute key.("acct_A") == key.("acct_B")
    end
  end
end
