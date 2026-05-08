defmodule Tymeslot.MeetingPayments.ConnectAccountSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Tymeslot.MeetingPayments.ConnectAccountSchema

  test "creating placeholder is valid" do
    cs =
      ConnectAccountSchema.changeset(%ConnectAccountSchema{}, %{
        user_id: 1,
        country: "ch",
        status: "creating"
      })

    assert cs.valid?
  end

  test "rejects unknown status" do
    cs =
      ConnectAccountSchema.changeset(%ConnectAccountSchema{}, %{
        user_id: 1,
        country: "ch",
        status: "weird"
      })

    refute cs.valid?
    assert "is invalid" in errors_on(cs).status
  end

  test "stripe_account_id must be unique" do
    user_a = insert(:user)
    user_b = insert(:user)

    {:ok, _account} =
      %ConnectAccountSchema{}
      |> ConnectAccountSchema.changeset(%{
        user_id: user_a.id,
        stripe_account_id: "acct_123",
        country: "ch",
        status: "active"
      })
      |> Repo.insert()

    {:error, cs} =
      %ConnectAccountSchema{}
      |> ConnectAccountSchema.changeset(%{
        user_id: user_b.id,
        stripe_account_id: "acct_123",
        country: "ch",
        status: "active"
      })
      |> Repo.insert()

    assert "has already been taken" in errors_on(cs).stripe_account_id
  end
end
