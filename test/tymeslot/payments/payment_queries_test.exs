defmodule Tymeslot.Payments.PaymentQueriesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

  alias Ecto.Changeset
  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.Repo
  alias Tymeslot.TestFixtures

  setup do
    user = TestFixtures.create_user_fixture()
    %{user: user}
  end

  describe "create_transaction/1" do
    test "creates a payment transaction with valid attributes", %{user: user} do
      attrs = %{
        user_id: user.id,
        amount: 500,
        status: "pending",
        stripe_id: "ch_test_123",
        product_identifier: "pro_monthly"
      }

      assert {:ok, transaction} = PaymentQueries.create_transaction(attrs)
      assert transaction.user_id == user.id
      assert transaction.amount == 500
      assert transaction.status == "pending"
      assert transaction.stripe_id == "ch_test_123"
      assert transaction.product_identifier == "pro_monthly"
    end

    test "requires user_id", %{user: _user} do
      attrs = %{
        amount: 500,
        status: "pending"
      }

      assert {:error, changeset} = PaymentQueries.create_transaction(attrs)
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "requires amount", %{user: user} do
      attrs = %{
        user_id: user.id,
        status: "pending"
      }

      assert {:error, changeset} = PaymentQueries.create_transaction(attrs)
      assert "can't be blank" in errors_on(changeset).amount
    end

    test "validates status is in allowed list", %{user: user} do
      attrs = %{
        user_id: user.id,
        amount: 500,
        status: "invalid_status"
      }

      assert {:error, changeset} = PaymentQueries.create_transaction(attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "returns an error tuple instead of raising for a negative tax_amount", %{user: user} do
      attrs = %{
        user_id: user.id,
        amount: 500,
        status: "pending",
        tax_amount: -500
      }

      assert {:error, changeset} = PaymentQueries.create_transaction(attrs)
      assert "must be greater than or equal to 0" in errors_on(changeset).tax_amount
    end

    test "returns an error tuple instead of raising for a negative discount_amount", %{
      user: user
    } do
      attrs = %{
        user_id: user.id,
        amount: 500,
        status: "pending",
        discount_amount: -100
      }

      assert {:error, changeset} = PaymentQueries.create_transaction(attrs)
      assert "must be greater than or equal to 0" in errors_on(changeset).discount_amount
    end

    test "prevents duplicate stripe_id", %{user: user} do
      attrs = %{
        user_id: user.id,
        amount: 500,
        status: "pending",
        stripe_id: "ch_test_dup"
      }

      assert {:ok, _result} = PaymentQueries.create_transaction(attrs)
      assert {:error, changeset} = PaymentQueries.create_transaction(attrs)
      assert "has already been taken" in errors_on(changeset).stripe_id
    end

    test "prevents multiple pending transactions per user", %{user: user} do
      attrs = %{
        user_id: user.id,
        amount: 500,
        status: "pending"
      }

      assert {:ok, _result} = PaymentQueries.create_transaction(attrs)
      assert {:error, changeset} = PaymentQueries.create_transaction(attrs)
      assert "has already been taken" in errors_on(changeset).user_id
    end

    test "allows zero-amount transactions", %{user: user} do
      attrs = %{
        user_id: user.id,
        amount: 0,
        status: "completed",
        stripe_id: "ch_test_zero"
      }

      assert {:ok, transaction} = PaymentQueries.create_transaction(attrs)
      assert transaction.amount == 0
    end
  end

  describe "get_transaction_by_stripe_id/1" do
    test "returns transaction when it exists", %{user: user} do
      transaction = PaymentTestHelpers.create_test_transaction(%{user_id: user.id})

      assert {:ok, found} = PaymentQueries.get_transaction_by_stripe_id(transaction.stripe_id)
      assert found.id == transaction.id
    end

    test "returns error when transaction doesn't exist" do
      assert {:error, :transaction_not_found} =
               PaymentQueries.get_transaction_by_stripe_id("nonexistent")
    end
  end

  describe "get_active_subscription_transaction_by_subscription_id/1" do
    test "breaks a tied inserted_at with id, deterministically returning the newest row", %{
      user: user
    } do
      first =
        PaymentTestHelpers.create_test_transaction(%{
          user_id: user.id,
          status: "completed",
          subscription_id: "sub_tie"
        })

      second =
        PaymentTestHelpers.create_test_transaction(%{
          user_id: user.id,
          status: "completed",
          subscription_id: "sub_tie"
        })

      tie = DateTime.utc_now(:second)

      Repo.update_all(
        from(t in PaymentTransactionSchema, where: t.id in ^[first.id, second.id]),
        set: [inserted_at: tie]
      )

      assert {:ok, found} =
               PaymentQueries.get_active_subscription_transaction_by_subscription_id("sub_tie")

      assert found.id == second.id
    end
  end

  describe "get_transaction_by_stripe_customer_id/1" do
    test "returns the most recent completed transaction for the customer", %{
      user: user
    } do
      older =
        PaymentTestHelpers.create_test_transaction(%{
          user_id: user.id,
          status: "completed",
          stripe_id: "cs_older",
          stripe_customer_id: "cus_shared"
        })

      # Newer than `older`, but still pending: not an ownership signal, so
      # the completed row must win even though it isn't the latest.
      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "pending",
        stripe_id: "cs_newer",
        stripe_customer_id: "cus_shared"
      })

      assert {:ok, found} = PaymentQueries.get_transaction_by_stripe_customer_id("cus_shared")
      assert found.id == older.id
    end

    test "returns error when the only match is not completed", %{user: user} do
      PaymentTestHelpers.create_test_transaction(%{
        user_id: user.id,
        status: "pending",
        stripe_id: "cs_pending_only",
        stripe_customer_id: "cus_pending_only"
      })

      assert {:error, :transaction_not_found} =
               PaymentQueries.get_transaction_by_stripe_customer_id("cus_pending_only")
    end

    test "returns error when no transaction matches the customer" do
      assert {:error, :transaction_not_found} =
               PaymentQueries.get_transaction_by_stripe_customer_id("cus_missing")
    end
  end

  describe "update_transaction/2" do
    test "updates transaction status", %{user: user} do
      transaction = PaymentTestHelpers.create_test_transaction(%{user_id: user.id})

      assert {:ok, updated} =
               PaymentQueries.update_transaction(transaction, %{status: "completed"})

      assert updated.status == "completed"
    end

    test "updates tax information", %{user: user} do
      transaction = PaymentTestHelpers.create_test_transaction(%{user_id: user.id})

      tax_attrs = %{
        tax_amount: 50,
        tax_rate: Decimal.new("0.10"),
        country_code: "DE"
      }

      assert {:ok, updated} = PaymentQueries.update_transaction(transaction, tax_attrs)
      assert updated.tax_amount == 50
      assert Decimal.equal?(updated.tax_rate, Decimal.new("0.10"))
      assert updated.country_code == "DE"
    end
  end

  describe "anonymise_for_host/2" do
    test "nilifies user_id, stamps host_deleted_at, retains host PII", %{user: user} do
      transaction = PaymentTestHelpers.create_test_transaction(%{user_id: user.id})

      # The migration backfills these columns from the users table; simulate
      # that snapshot here so we can assert it survives anonymisation.
      {:ok, transaction} =
        transaction
        |> Changeset.change(%{host_email: "host@example.com", host_name: "Host"})
        |> Repo.update()

      now = DateTime.utc_now(:second)

      assert {1, nil} = PaymentQueries.anonymise_for_host(user.id, now)

      reloaded = Repo.get!(PaymentTransactionSchema, transaction.id)
      assert reloaded.user_id == nil
      assert reloaded.host_deleted_at == now
      assert reloaded.host_email == "host@example.com"
      assert reloaded.host_name == "Host"
    end

    test "skips already-anonymised rows", %{user: user} do
      transaction = PaymentTestHelpers.create_test_transaction(%{user_id: user.id})
      earlier = DateTime.add(DateTime.utc_now(:second), -3600, :second)

      {:ok, _updated} =
        transaction
        |> Changeset.change(%{host_deleted_at: earlier})
        |> Repo.update()

      now = DateTime.utc_now(:second)

      assert {0, nil} = PaymentQueries.anonymise_for_host(user.id, now)

      reloaded = Repo.get!(PaymentTransactionSchema, transaction.id)
      assert reloaded.host_deleted_at == earlier
    end
  end
end
