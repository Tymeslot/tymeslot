defmodule Tymeslot.MeetingPayments.ConnectAccountSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Tymeslot.MeetingPayments.ConnectAccountSchema

  test "default status is 'creating' when none is supplied" do
    # Verifies I-4: both the Ecto schema default and the DB column default are
    # aligned to "creating" so any insert path that omits status is safe.
    user = insert(:user)

    {:ok, account} =
      %ConnectAccountSchema{}
      |> ConnectAccountSchema.changeset(%{user_id: user.id, country: "ch"})
      |> Repo.insert()

    assert account.status == "creating"

    # Reload from DB to confirm the column default (not just the in-memory struct).
    reloaded = Repo.get!(ConnectAccountSchema, account.id)
    assert reloaded.status == "creating"
  end

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
