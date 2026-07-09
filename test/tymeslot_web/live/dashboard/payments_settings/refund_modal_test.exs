defmodule TymeslotWeb.Dashboard.PaymentsSettings.RefundModalTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.PaymentsSettings.RefundModal

  defp render_modal(payment) do
    render_component(&RefundModal.refund_modal/1,
      payment: payment,
      submitting: false,
      myself: nil
    )
  end

  describe "refund_modal/1" do
    test "renders nothing when there is no payment" do
      assert render_modal(nil) =~ ""
      refute render_modal(nil) =~ "refund-modal"
      refute render_modal(nil) =~ "Refund payment"
    end

    test "renders the original, refunded, and remaining amounts for a payment" do
      payment = %{
        id: 42,
        attendee_name: "Alice",
        attendee_email: "alice@example.com",
        meeting_type_name: "Consult",
        amount_cents: 5000,
        refunded_amount_cents: 1500,
        currency: "eur"
      }

      html = render_modal(payment)

      assert html =~ "Refund payment"
      # Attendee and meeting type must appear together inside the single
      # interpolated sentence — guards against the message being re-split into
      # gettext fragments around the values.
      assert html =~ "Refund Alice for Consult."
      assert html =~ "id=\"refund-form\""
      # Original charge
      assert html =~ "€50.00"
      # Already refunded
      assert html =~ "€15.00"
      # Remaining refundable (5000 - 1500 = 3500)
      assert html =~ "€35.00"
    end

    test "renders the currency symbol as the amount field's leading icon" do
      payment = %{
        id: 7,
        attendee_name: "Bob",
        attendee_email: "bob@example.com",
        meeting_type_name: "Coaching",
        amount_cents: 4000,
        refunded_amount_cents: 0,
        currency: "gbp"
      }

      html = render_modal(payment)

      assert html =~ "£"
    end
  end
end
