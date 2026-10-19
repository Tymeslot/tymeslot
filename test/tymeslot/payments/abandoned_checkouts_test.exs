defmodule Tymeslot.Payments.AbandonedCheckoutsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :payments

  alias Tymeslot.Payments
  alias Tymeslot.Payments.PaymentTransactionSchema

  setup do
    %{cutoff: DateTime.add(DateTime.utc_now(), -600, :second)}
  end

  defp pending(user, age_seconds, attrs \\ []) do
    tx = insert(:payment_transaction, [user: user, status: "pending"] ++ attrs)
    at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)

    Repo.update_all(from(t in PaymentTransactionSchema, where: t.id == ^tx.id),
      set: [inserted_at: at]
    )

    tx
  end

  defp handled?(tx),
    do: Repo.get!(PaymentTransactionSchema, tx.id).metadata["abandoned_email_sent"] == "true"

  describe "list_abandoned_checkouts/1" do
    test "lists users whose pending checkout is older than the cutoff", %{cutoff: cutoff} do
      user = insert(:user)
      pending(user, 700)
      insert(:payment_transaction, user: user, status: "completed")
      fresh = insert(:user)
      pending(fresh, 60)

      assert Payments.list_abandoned_checkouts(cutoff: cutoff) == [{user.id, 1}]
    end

    test "leaves out checkouts already handled", %{cutoff: cutoff} do
      user = insert(:user)
      pending(user, 700, metadata: %{"abandoned_email_sent" => "true"})
      other = insert(:user)
      pending(other, 700, metadata: %{"abandoned_email_sent" => "false"})

      assert Payments.list_abandoned_checkouts(cutoff: cutoff) == [{other.id, 1}]
    end

    test "narrows by product and payment type", %{cutoff: cutoff} do
      wanted = insert(:user)

      pending(wanted, 700,
        product_identifier: "pro",
        metadata: %{"payment_type" => "subscription"}
      )

      wrong_product = insert(:user)

      pending(wrong_product, 700,
        product_identifier: "other",
        metadata: %{"payment_type" => "subscription"}
      )

      wrong_type = insert(:user)

      pending(wrong_type, 700,
        product_identifier: "pro",
        metadata: %{"payment_type" => "one_off"}
      )

      assert Payments.list_abandoned_checkouts(
               cutoff: cutoff,
               product_identifiers: ["pro"],
               payment_type: "subscription"
             ) == [{wanted.id, 1}]
    end
  end

  describe "mark_abandoned_checkouts_handled/2" do
    test "marks the user's checkouts past the cutoff, which then drop out of the list", %{
      cutoff: cutoff
    } do
      user = insert(:user)
      tx = pending(user, 700, metadata: %{"payment_type" => "subscription"})

      assert Payments.mark_abandoned_checkouts_handled(user.id, cutoff: cutoff) == 1
      assert handled?(tx)
      assert Repo.get!(PaymentTransactionSchema, tx.id).metadata["payment_type"] == "subscription"
      assert Payments.list_abandoned_checkouts(cutoff: cutoff) == []
    end

    # A user holds at most one pending checkout, so the one a run listed can be
    # replaced by a fresh checkout before it is marked; the fresh one keeps its
    # own follow-up.
    test "leaves a checkout started after the cutoff alone", %{cutoff: cutoff} do
      user = insert(:user)
      fresh = pending(user, 60)

      assert Payments.mark_abandoned_checkouts_handled(user.id, cutoff: cutoff) == 0
      refute handled?(fresh)
    end

    test "touches only the given user's checkouts under the same filters", %{cutoff: cutoff} do
      user = insert(:user)
      other_product = pending(user, 700, product_identifier: "other")
      other_user_tx = pending(insert(:user), 700)

      assert Payments.mark_abandoned_checkouts_handled(user.id,
               cutoff: cutoff,
               product_identifiers: ["pro"]
             ) == 0

      refute handled?(other_product)
      refute handled?(other_user_tx)
    end
  end
end
