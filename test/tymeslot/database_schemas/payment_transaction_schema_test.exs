defmodule Tymeslot.DatabaseSchemas.PaymentTransactionSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :schema
  @moduletag :payments

  import Ecto.Changeset
  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.PaymentTransactionSchema

  describe "changeset/2" do
    test "valid with required fields" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        amount: 1000,
        status: "completed"
      }

      changeset = PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, %{})
      refute changeset.valid?

      assert %{
               user_id: ["can't be blank"],
               amount: ["can't be blank"],
               status: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates status inclusion with valid values" do
      user = insert(:user)

      for status <- ~w(pending completed failed pending_reconciliation) do
        changeset =
          PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, %{
            user_id: user.id,
            amount: 500,
            status: status
          })

        assert changeset.valid?, "expected status #{inspect(status)} to be valid"
      end
    end

    test "rejects invalid status" do
      user = insert(:user)

      changeset =
        PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, %{
          user_id: user.id,
          amount: 500,
          status: "refunded"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "validates amount is greater than or equal to 0" do
      user = insert(:user)

      changeset =
        PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, %{
          user_id: user.id,
          amount: -1,
          status: "completed"
        })

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).amount
    end

    test "allows zero amount" do
      user = insert(:user)

      changeset =
        PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, %{
          user_id: user.id,
          amount: 0,
          status: "completed"
        })

      assert changeset.valid?
    end

    test "validates country_code length is exactly 2" do
      user = insert(:user)

      changeset =
        PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, %{
          user_id: user.id,
          amount: 1000,
          status: "completed",
          country_code: "USA"
        })

      refute changeset.valid?
      assert "should be 2 character(s)" in errors_on(changeset).country_code
    end

    test "accepts valid 2-character country_code" do
      user = insert(:user)

      changeset =
        PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, %{
          user_id: user.id,
          amount: 1000,
          status: "completed",
          country_code: "US"
        })

      assert changeset.valid?
    end

    test "unique constraint on stripe_id" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        amount: 1000,
        status: "completed",
        stripe_id: "pi_abc123"
      }

      {:ok, _transaction} =
        %PaymentTransactionSchema{}
        |> PaymentTransactionSchema.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %PaymentTransactionSchema{}
        |> PaymentTransactionSchema.changeset(attrs)
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).stripe_id
    end

    test "accepts optional fields" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        amount: 2500,
        status: "completed",
        stripe_id: "pi_optional_test",
        stripe_customer_id: "cus_123",
        product_identifier: "pro_monthly",
        subscription_id: "sub_456",
        subscription_period: "monthly",
        tax_amount: 250,
        tax_rate: Decimal.new("0.10"),
        discount_amount: 100,
        tax_id: "EU123456",
        is_eu_business: true,
        country_code: "DE",
        billing_address: %{"city" => "Berlin"},
        payment_method: "card",
        metadata: %{"source" => "web"}
      }

      changeset = PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, attrs)
      assert changeset.valid?
    end

    test "applies default values" do
      user = insert(:user)

      changeset =
        PaymentTransactionSchema.changeset(%PaymentTransactionSchema{}, %{
          user_id: user.id,
          amount: 1000,
          status: "completed"
        })

      assert get_field(changeset, :is_eu_business) == false
      assert get_field(changeset, :metadata) == %{}
    end

    test "unique constraint on pending transaction per user" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        amount: 1000,
        status: "pending"
      }

      {:ok, _transaction} =
        %PaymentTransactionSchema{}
        |> PaymentTransactionSchema.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %PaymentTransactionSchema{}
        |> PaymentTransactionSchema.changeset(%{attrs | amount: 2000})
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).user_id
    end

    test "allows multiple completed transactions for the same user" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        amount: 1000,
        status: "completed"
      }

      {:ok, _transaction1} =
        %PaymentTransactionSchema{}
        |> PaymentTransactionSchema.changeset(attrs)
        |> Repo.insert()

      {:ok, _transaction2} =
        %PaymentTransactionSchema{}
        |> PaymentTransactionSchema.changeset(%{attrs | amount: 2000})
        |> Repo.insert()
    end
  end
end
