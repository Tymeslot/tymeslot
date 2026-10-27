defmodule Tymeslot.Workers.SendConnectAccountRestrictedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :payments

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.Workers.SendConnectAccountRestricted

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1, which is the CircuitBreaker GenServer, not the test
  # process. Pointing the adapter here collects the delivered email instead.
  # Safe because the module is `async: false`.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

  defp insert_account(attrs \\ %{}, user_attrs \\ %{}) do
    user = insert(:user, Map.merge(%{email: "host@example.com", name: "Bob Host"}, user_attrs))

    defaults = %{
      user: user,
      stripe_account_id: "acct_RESTRICTED",
      country: "ch",
      default_currency: "chf",
      charges_enabled: false,
      payouts_enabled: false,
      details_submitted: true,
      disabled_reason: "requirements.past_due",
      status: "active"
    }

    insert(:connect_account, Map.merge(defaults, Map.new(attrs)))
  end

  describe "perform/1" do
    test "succeeds for a restricted account with a valid user" do
      account = insert_account()

      assert :ok =
               perform_job(SendConnectAccountRestricted, %{
                 "connect_account_id" => account.id,
                 "user_id" => account.user_id,
                 "stripe_account_id" => account.stripe_account_id,
                 "disabled_reason" => "requirements.past_due"
               })
    end

    test "writes the delivered alert in the host's own language" do
      account = insert_account(%{}, %{locale: "de"})

      assert :ok =
               perform_job(SendConnectAccountRestricted, %{
                 "connect_account_id" => account.id,
                 "user_id" => account.user_id,
                 "stripe_account_id" => account.stripe_account_id,
                 "disabled_reason" => "requirements.past_due"
               })

      assert_received {:email, email}
      assert email.to == [{"Bob Host", "host@example.com"}]
      assert email.subject == "Stripe-Konto eingeschränkt: Handlungsbedarf"
      assert email.text_body =~ "Hallo Bob Host,"
      refute email.text_body =~ "RESTORE YOUR ACCOUNT"
    end

    test "discards when connect_account is missing" do
      assert {:discard, "connect_account not found"} =
               perform_job(SendConnectAccountRestricted, %{
                 "connect_account_id" => UUID.generate()
               })
    end

    test "discards when connect_account has no user_id" do
      account = insert_account()

      {:ok, account} =
        ConnectAccountQueries.update(account, %{
          user_id: nil,
          deleted_at: DateTime.utc_now(:second),
          status: "deleted",
          charges_enabled: false
        })

      assert {:discard, "missing user_id"} =
               perform_job(SendConnectAccountRestricted, %{
                 "connect_account_id" => account.id
               })
    end

    test "discards when args are missing connect_account_id" do
      assert {:discard, "missing connect_account_id"} =
               perform_job(SendConnectAccountRestricted, %{})
    end
  end

  describe "uniqueness" do
    test "second Oban.insert for the same connect_account_id within 24 h is a conflict" do
      account = insert_account()

      args = %{
        "connect_account_id" => account.id,
        "user_id" => account.user_id,
        "stripe_account_id" => account.stripe_account_id,
        "disabled_reason" => "requirements.past_due"
      }

      assert {:ok, %{conflict?: false}} = Oban.insert(SendConnectAccountRestricted.new(args))
      assert {:ok, %{conflict?: true}} = Oban.insert(SendConnectAccountRestricted.new(args))
    end
  end
end
