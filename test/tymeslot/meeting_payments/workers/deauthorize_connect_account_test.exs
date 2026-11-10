defmodule Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccountTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments

  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers

  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount

  setup :verify_on_exit!
  setup :capture_admin_alerts

  test "revokes an account with no live row" do
    insert(:connect_account,
      stripe_account_id: "acct_GONE",
      user: nil,
      status: :deleted,
      deleted_at: DateTime.utc_now(:second)
    )

    expect(StripeAdapterMock, :deauthorize_account, fn "acct_GONE" -> :ok end)

    assert :ok = perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_GONE"})
  end

  test "leaves an account that has been reconnected" do
    insert(:connect_account, stripe_account_id: "acct_BACK")

    # No expectation: verify_on_exit! and Mox fail the test on any call.
    assert :ok = perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_BACK"})
  end

  test "treats not_connected as done" do
    expect(StripeAdapterMock, :deauthorize_account, fn "acct_NC" -> {:error, :not_connected} end)

    assert :ok = perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_NC"})
  end

  @tag :capture_log
  test "discards a job with malformed args" do
    assert {:discard, _reason} = perform_job(DeauthorizeConnectAccount, %{})
  end

  test "retries other failures" do
    expect(StripeAdapterMock, :deauthorize_account, fn "acct_ERR" -> {:error, :oauth_failed} end)

    assert {:error, :oauth_failed} =
             perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_ERR"})
  end

  test "a failure before the last attempt does not alert" do
    expect(StripeAdapterMock, :deauthorize_account, fn "acct_ERR" -> {:error, :oauth_failed} end)

    assert {:error, :oauth_failed} =
             perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_ERR"},
               attempt: 19
             )

    refute_received {:send_alert, _type, _payload}
  end

  @tag :capture_log
  test "a failure on the last attempt alerts an admin with the account and a reason" do
    expect(StripeAdapterMock, :deauthorize_account, fn "acct_ERR" -> {:error, :oauth_failed} end)

    assert {:error, :oauth_failed} =
             perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_ERR"},
               attempt: 20
             )

    assert_received {:send_alert, :connect_revocation_failed,
                     %{stripe_account_id: "acct_ERR"} = alert}

    assert alert.reason_code == :oauth_failed
    assert is_integer(alert.oban_job_id)
  end
end
