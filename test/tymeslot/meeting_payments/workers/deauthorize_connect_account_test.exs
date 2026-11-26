defmodule Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccountTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.StripeConnectTestHelpers, only: [expect_deauthorize: 2]

  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount
  alias Tymeslot.Repo

  setup :capture_admin_alerts

  test "revokes an account with no live row" do
    insert(:connect_account,
      stripe_account_id: "acct_GONE",
      user: nil,
      status: :deleted,
      deleted_at: DateTime.utc_now(:second)
    )

    expect_deauthorize("acct_GONE", :ok)

    assert :ok = perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_GONE"})
    assert_received {:oauth_deauthorize, "acct_GONE"}
  end

  test "leaves an account that has been reconnected" do
    insert(:connect_account, stripe_account_id: "acct_BACK")

    # No OAuth stub: a request fails the job.
    assert :ok = perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_BACK"})
  end

  test "treats not_connected as done" do
    expect_deauthorize("acct_NC", {:error, :not_connected})

    assert :ok = perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_NC"})
  end

  @tag :capture_log
  test "cancels without alerting when Stripe refuses a platform-controlled account" do
    expect_deauthorize("acct_CTL", {:error, :controlled_account})

    assert {:cancel, :controlled_account} =
             perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_CTL"},
               attempt: 20
             )

    refute_received {:send_alert, _type, _payload}
  end

  @tag :capture_log
  test "discards a job with malformed args" do
    assert {:discard, _reason} = perform_job(DeauthorizeConnectAccount, %{})
  end

  test "retries other failures" do
    expect_deauthorize("acct_ERR", {:error, :oauth_failed})

    assert {:error, :oauth_failed} =
             perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_ERR"})
  end

  test "a failure before the last attempt does not alert" do
    expect_deauthorize("acct_ERR", {:error, :oauth_failed})

    assert {:error, :oauth_failed} =
             perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_ERR"},
               attempt: 19
             )

    refute_received {:send_alert, _type, _payload}
  end

  @tag :capture_log
  test "a failure on the last attempt alerts an admin with the account and a reason" do
    expect_deauthorize("acct_ERR", {:error, :oauth_failed})

    assert {:error, :oauth_failed} =
             perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_ERR"},
               attempt: 20
             )

    assert_received {:send_alert, :connect_revocation_failed,
                     %{stripe_account_id: "acct_ERR"} = alert}

    assert alert.reason_code == :oauth_failed
    assert is_integer(alert.oban_job_id)
  end

  describe "without STRIPE_CONNECT_CLIENT_ID" do
    setup do
      previous = Application.get_env(:tymeslot, :stripe_connect_client_id)
      Application.delete_env(:tymeslot, :stripe_connect_client_id)
      on_exit(fn -> Application.put_env(:tymeslot, :stripe_connect_client_id, previous) end)
    end

    # No OAuth stub: a request fails the job, so nothing is sent to Stripe
    # with an empty client ID.
    test "fails without calling Stripe, so the job retries" do
      assert {:error, :oauth_not_configured} =
               perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_NOID"},
                 attempt: 1
               )

      refute_received {:send_alert, _type, _payload}
    end

    @tag :capture_log
    test "alerts an admin on the last attempt" do
      assert {:error, :oauth_not_configured} =
               perform_job(DeauthorizeConnectAccount, %{"stripe_account_id" => "acct_NOID"},
                 attempt: 20
               )

      assert_received {:send_alert, :connect_revocation_failed,
                       %{stripe_account_id: "acct_NOID", reason_code: :oauth_not_configured}}
    end
  end

  describe "schedule/2" do
    test "moves a job that is waiting to retry, so a disconnect's delay is not cut short" do
      assert {:ok, first} = DeauthorizeConnectAccount.schedule("acct_RETRY", 0)

      soon = DateTime.add(DateTime.utc_now(), 30)

      first
      |> Changeset.change(state: "retryable", attempt: 1, scheduled_at: soon)
      |> Repo.update!()

      assert {:ok, _job} = DeauthorizeConnectAccount.schedule("acct_RETRY", 35 * 60)

      job = Repo.get!(Job, first.id)
      assert job.state == "retryable"

      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now(:second)), 35 * 60, 60
    end
  end
end
