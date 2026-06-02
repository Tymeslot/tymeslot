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

  describe "get_transactions_by_status/1" do
    test "returns transactions with given status", %{user: user} do
      other_user = TestFixtures.create_user_fixture()

      _pending1 =
        PaymentTestHelpers.create_test_transaction(%{user_id: user.id, status: "pending"})

      _pending2 =
        PaymentTestHelpers.create_test_transaction(%{user_id: other_user.id, status: "pending"})

      _completed =
        PaymentTestHelpers.create_test_transaction(%{user_id: user.id, status: "completed"})

      assert {:ok, transactions} = PaymentQueries.get_transactions_by_status("pending")
      assert length(transactions) == 2
      assert Enum.all?(transactions, fn t -> t.status == "pending" end)
    end

    test "returns empty list when no transactions match", %{user: _user} do
      assert {:ok, transactions} = PaymentQueries.get_transactions_by_status("pending")
      assert transactions == []
    end
  end

  describe "coordinate_successful_payment/3" do
    test "updates transaction with tax info and marks as completed", %{user: user} do
      transaction =
        PaymentTestHelpers.create_test_transaction(%{
          user_id: user.id,
          status: "pending",
          stripe_id: "ch_test_success"
        })

      tax_info = %{
        tax_amount: 100,
        tax_rate: Decimal.new("0.20"),
        country_code: "FR",
        is_eu_business: true
      }

      assert {:ok, updated} =
               PaymentQueries.coordinate_successful_payment(
                 transaction.stripe_id,
                 tax_info,
                 50
               )

      assert updated.status == "completed"
      assert updated.tax_amount == 100
      assert Decimal.equal?(updated.tax_rate, Decimal.new("0.20"))
      assert updated.country_code == "FR"
      assert updated.is_eu_business == true
      assert updated.discount_amount == 50
    end

    test "returns error when transaction not found" do
      tax_info = %{tax_amount: 100}

      assert {:error, :transaction_not_found} =
               PaymentQueries.coordinate_successful_payment("nonexistent", tax_info, 0)
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
