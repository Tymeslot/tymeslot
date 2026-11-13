defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypesConnectRevocationTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  describe "the alert for a Stripe revocation that kept failing" do
    test ":connect_revocation_failed names the account and the job to retry" do
      metadata = %{
        stripe_account_id: "acct_STUCK",
        oban_job_id: 77,
        reason_message: "oauth_failed"
      }

      msg = AlertTypes.format_message(:connect_revocation_failed, metadata)

      assert msg =~ "acct_STUCK"
      assert msg =~ "retry Oban job 77"
      assert msg =~ "oauth_failed"
    end

    test ":connect_revocation_failed dedups per account" do
      key = &AlertTypes.dedup_key(:connect_revocation_failed, %{stripe_account_id: &1})

      assert key.("acct_A") == key.("acct_A")
      refute key.("acct_A") == key.("acct_B")
    end
  end
end
