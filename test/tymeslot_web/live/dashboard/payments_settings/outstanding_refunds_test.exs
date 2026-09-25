defmodule TymeslotWeb.Dashboard.PaymentsSettings.OutstandingRefundsTest do
  @moduledoc """
  The display branches of the "Refunds outstanding" card.

  Two of them only exist because the card outlives the Connect account it used
  to live inside: a host who has disconnected Stripe is handed no account at
  all, and must still see the debt, with every row pointing at Stripe rather
  than offering a button that cannot work. The third is the bounded window
  saying how much it is hiding, since a full table with nothing missing looks
  exactly like a full table with thirteen rows missing.
  """

  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.UUID
  alias TymeslotWeb.Dashboard.PaymentsSettings.OutstandingRefunds

  defp payment(attrs \\ %{}) do
    defaults = %{
      id: UUID.generate(),
      attendee_email: "outofpocket@example.com",
      amount_cents: 5000,
      currency: "eur",
      meeting: build(:meeting, status: "cancelled", cancelled_at: DateTime.utc_now(:second))
    }

    build(:paid_booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  defp render_card(opts) do
    payments = Keyword.get(opts, :payments, [payment()])

    render_component(&OutstandingRefunds.outstanding_refunds/1,
      payments: payments,
      total_count: Keyword.get(opts, :total_count, length(payments)),
      account: Keyword.get(opts, :account, build(:connect_account)),
      myself: nil
    )
  end

  describe "with no Connect account" do
    test "lists the debt but sends the host to Stripe to settle it" do
      html = render_card(account: nil)

      assert html =~ "Refunds outstanding"
      assert html =~ "outofpocket@example.com"
      assert html =~ "€50.00"
      assert html =~ "Refund in Stripe"
      refute html =~ "open_refund_modal"
    end

    test "says why the refund cannot be issued from here" do
      html = render_card(account: nil)

      assert html =~ "Your Stripe account is not connected"
      assert html =~ "The money is still owed."
    end

    test "offers the refund again once an account is connected" do
      html = render_card(account: build(:connect_account))

      assert html =~ "open_refund_modal"
      refute html =~ "Your Stripe account is not connected"
    end

    # A stale assign can still carry the soft-deleted row during a reconnect,
    # and it is no more able to issue a refund than its absence is.
    test "treats a soft-deleted account the same as none at all" do
      html = render_card(account: build(:connect_account, deleted_at: DateTime.utc_now(:second)))

      assert html =~ "Refund in Stripe"
      refute html =~ "open_refund_modal"
    end
  end

  describe "the bounded window" do
    test "says how many rows it is not showing" do
      html = render_card(payments: [payment(), payment()], total_count: 63)

      assert html =~ "Showing the 2 oldest of 63 outstanding refunds."
    end

    test "says nothing when the window holds everything" do
      html = render_card(payments: [payment(), payment()], total_count: 2)

      refute html =~ "Showing the"
    end
  end
end
