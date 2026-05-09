defmodule Tymeslot.MeetingPayments.Webhooks.AccountUpdatedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.Webhooks.AccountUpdated

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

      now = System.os_time(:second)

      event = %{
        "id" => "evt_ACCT",
        "type" => "account.updated",
        "created" => now,
        "data" => %{
          "object" => %{
            "id" => "acct_LIVE",
            "created" => now,
            "charges_enabled" => true,
            "payouts_enabled" => true,
            "details_submitted" => true,
            "requirements" => %{"disabled_reason" => nil}
          }
        }
      }

      assert :ok = AccountUpdated.handle(event)

      reloaded = ConnectAccountQueries.by_stripe_account_id("acct_LIVE")
      assert reloaded.id == ca.id
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
      assert reloaded.details_submitted == true
      assert reloaded.last_account_event_at
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

      stale_event_created = DateTime.to_unix(stored_event_at) - 60

      event = %{
        "id" => "evt_OLD",
        "type" => "account.updated",
        "created" => stale_event_created,
        "data" => %{
          "object" => %{
            "id" => "acct_OUT_OF_ORDER",
            "created" => stale_event_created,
            "charges_enabled" => false,
            "payouts_enabled" => false
          }
        }
      }

      assert :ok = AccountUpdated.handle(event)

      reloaded = ConnectAccountQueries.by_stripe_account_id("acct_OUT_OF_ORDER")
      assert reloaded.charges_enabled == true
      assert reloaded.payouts_enabled == true
    end

    test "returns :ok when no connect_account matches the stripe_account_id" do
      now = System.os_time(:second)

      event = %{
        "id" => "evt_NOMATCH",
        "type" => "account.updated",
        "created" => now,
        "data" => %{
          "object" => %{
            "id" => "acct_GHOST",
            "created" => now,
            "charges_enabled" => true
          }
        }
      }

      assert :ok = AccountUpdated.handle(event)
    end
  end
end
