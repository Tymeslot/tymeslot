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
end
