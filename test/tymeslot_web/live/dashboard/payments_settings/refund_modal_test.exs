defmodule TymeslotWeb.Dashboard.PaymentsSettings.RefundModalTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
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
      payment = %BookingPaymentSchema{
        id: 42,
        attendee_name: "Alice",
        attendee_email: "alice@example.com",
        meeting_type_name: "Consult",
        amount_cents: 5000,
        refunded_amount_cents: 1500,
        stripe_refunded_cents: 1500,
        currency: "eur",
        pending_refund_cents: 0
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
      payment = %BookingPaymentSchema{
        id: 7,
        attendee_name: "Bob",
        attendee_email: "bob@example.com",
        meeting_type_name: "Coaching",
        amount_cents: 4000,
        refunded_amount_cents: 0,
        currency: "gbp",
        pending_refund_cents: 0
      }

      html = render_modal(payment)

      assert html =~ "£"
    end
  end

  describe "a lost dispute" do
    defp payment(attrs) do
      struct!(
        %BookingPaymentSchema{
          id: 9,
          attendee_name: "Carol",
          attendee_email: "carol@example.com",
          meeting_type_name: "Review",
          amount_cents: 10_000,
          currency: "eur",
          pending_refund_cents: 0
        },
        attrs
      )
    end

    test "the refund dialog separates a lost dispute from refunds" do
      html =
        render_modal(
          payment(
            refunded_amount_cents: 10_000,
            stripe_refunded_cents: 4_000,
            disputed_lost_cents: 6_000
          )
        )

      assert html =~ ~r/<p>\s*Already refunded:\s*<strong>€40.00<\/strong>\s*<\/p>/
      assert html =~ ~r/<p>\s*Lost in a dispute:\s*<strong>€60.00<\/strong>\s*<\/p>/
      assert html =~ ~r/Remaining refundable:\s*<strong>€0.00<\/strong>/
    end

    test "the refund dialog shows refunds a lost dispute over the same money repaid again" do
      html =
        render_modal(
          payment(
            refunded_amount_cents: 10_000,
            stripe_refunded_cents: 10_000,
            disputed_lost_cents: 10_000
          )
        )

      assert html =~ ~r/Already refunded:\s*<strong>€100.00<\/strong>/
      assert html =~ ~r/Lost in a dispute:\s*<strong>€100.00<\/strong>/
      assert html =~ ~r/Remaining refundable:\s*<strong>€0.00<\/strong>/
    end

    test "the refund dialog says when only the dispute took money back" do
      html = render_modal(payment(refunded_amount_cents: 6_000, disputed_lost_cents: 6_000))

      assert html =~ ~r/Already refunded:\s*<strong>€0.00<\/strong>/
      assert html =~ ~r/Lost in a dispute:\s*<strong>€60.00<\/strong>/
    end

    test "the refund dialog wording is unchanged without a dispute" do
      html = render_modal(payment(refunded_amount_cents: 4_000, stripe_refunded_cents: 4_000))

      assert html =~ ~r/Already refunded:\s*<strong>€40.00<\/strong>/
      refute html =~ "dispute"
    end

    test "pending refunds are not shown as refunded" do
      html =
        render_modal(
          payment(
            refunded_amount_cents: 2_000,
            stripe_refunded_cents: 2_000,
            pending_refund_cents: 3_000
          )
        )

      assert html =~ ~r/Already refunded:\s*<strong>€20.00<\/strong>/
      assert html =~ "€30.00 being processed"
      assert html =~ ~r/Remaining refundable:\s*<strong>€50.00<\/strong>/
    end
  end
end
