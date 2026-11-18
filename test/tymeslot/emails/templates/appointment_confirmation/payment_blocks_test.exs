defmodule Tymeslot.Emails.Templates.AppointmentConfirmation.PaymentBlocksTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails
  @moduletag :payments

  alias Tymeslot.Emails.Shared.Styles
  alias Tymeslot.Emails.Templates.AppointmentConfirmation.PaymentBlocks
  alias Tymeslot.Utils.Colour

  describe "attendee_receipt_html/1" do
    test "derives the receipt button text colour from the brand accent, clearing 4.5:1" do
      receipt = %{
        amount: "€50.00",
        paid_at: "8 May 2026",
        reference: "ch_TEST",
        receipt_url: "https://pay.stripe.com/receipts/r_TEST"
      }

      html = PaymentBlocks.attendee_receipt_html(receipt)
      accent_deep = Styles.intent_accent_deep(:confirmed)
      expected_text = Styles.button_text_color(accent_deep)

      assert html =~ ~s(color="#{expected_text}")
      assert Colour.contrast_ratio(expected_text, accent_deep) >= 4.5
    end

    test "the stock receipt button resolves to light text, not dark ink" do
      receipt = %{
        amount: "€50.00",
        paid_at: "8 May 2026",
        reference: "ch_TEST",
        receipt_url: "https://pay.stripe.com/receipts/r_TEST"
      }

      html = PaymentBlocks.attendee_receipt_html(receipt)

      assert html =~ ~s(background-color="#{Styles.intent_accent_deep(:confirmed)}")
      assert html =~ ~s(color="#{Styles.surface()}")
    end

    test "renders no button when there is no receipt URL" do
      receipt = %{amount: "€50.00", paid_at: nil, reference: nil, receipt_url: nil}

      html = PaymentBlocks.attendee_receipt_html(receipt)

      refute html =~ "View receipt"
    end
  end

  describe "seat counts" do
    defp details(seats) do
      %{
        booking_payment: %{
          status: :paid,
          amount_cents: 4000,
          currency: "eur",
          application_fee_cents: 200,
          seats: seats
        }
      }
    end

    test "a payment for several seats names them in the receipt and the payout summary" do
      receipt = PaymentBlocks.attendee_receipt(details(2))
      summary = PaymentBlocks.organizer_summary(details(2))

      assert receipt.seats == 2
      assert summary.seats == 2
      assert PaymentBlocks.attendee_receipt_text(receipt) =~ "For 2 seats"
      assert PaymentBlocks.organizer_summary_text(summary) =~ "For 2 seats"
      assert PaymentBlocks.organizer_summary_html(summary) =~ "For 2 seats"
    end

    test "a payment for one seat shows no seat count" do
      receipt = PaymentBlocks.attendee_receipt(details(1))
      summary = PaymentBlocks.organizer_summary(details(1))

      refute Map.has_key?(receipt, :seats)
      refute Map.has_key?(summary, :seats)
      refute PaymentBlocks.attendee_receipt_text(receipt) =~ "seat"
      refute PaymentBlocks.organizer_summary_text(summary) =~ "seat"
    end
  end
end
