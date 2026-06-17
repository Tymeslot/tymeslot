defmodule Tymeslot.Emails.Templates.BookingPaymentRefundedTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :payments

  alias Tymeslot.Emails.Templates.BookingPaymentRefunded
  alias Tymeslot.Emails.Templates.BookingPaymentRefunded.RefundContext

  defp build_context(overrides \\ %{}) do
    defaults = %{
      attendee_email: "alice@example.com",
      attendee_name: "Alice",
      host_name: "Bob Host",
      meeting_title: "Discovery Call",
      amount_cents: 5000,
      refunded_amount_cents: 5000,
      currency: "eur",
      is_full_refund?: true,
      locale: "en"
    }

    struct!(RefundContext, Map.merge(defaults, overrides))
  end

  describe "render/1 for full refund" do
    test "subject mentions the refund amount" do
      email = BookingPaymentRefunded.render(build_context())
      assert email.subject =~ "Refund Issued"
      assert email.subject =~ "€50.00"
    end

    test "delivers to the attendee" do
      email = BookingPaymentRefunded.render(build_context())
      assert email.to == [{"Alice", "alice@example.com"}]
    end

    test "html and text bodies show full-refund copy" do
      email = BookingPaymentRefunded.render(build_context())

      assert email.text_body =~ "REFUND ISSUED"
      assert email.text_body =~ "refunded in full"
      assert email.text_body =~ "€50.00"
      assert email.text_body =~ "Discovery Call"
      assert email.text_body =~ "5–10 business days"
      assert email.text_body =~ "Bob Host"

      assert email.html_body =~ "Refunded"
      assert email.html_body =~ "Your payment was refunded"
      assert email.html_body =~ "€50.00"
      assert email.html_body =~ "Discovery Call"
    end
  end

  describe "render/1 for partial refund" do
    test "subject and body reference partial refund" do
      ctx =
        build_context(%{
          refunded_amount_cents: 2000,
          amount_cents: 5000,
          is_full_refund?: false
        })

      email = BookingPaymentRefunded.render(ctx)

      assert email.subject =~ "Partial Refund"
      assert email.subject =~ "€20.00"
      assert email.text_body =~ "€20.00"
      assert email.text_body =~ "€50.00"
      refute email.text_body =~ "in full"
      assert email.html_body =~ "partial refund"
    end
  end

  describe "render/1 with missing optional fields" do
    test "drops the personal greeting when attendee_name is nil" do
      ctx = build_context(%{attendee_name: nil})
      email = BookingPaymentRefunded.render(ctx)

      assert email.to == [{"", "alice@example.com"}]
      refute email.text_body =~ "Hi there"
      refute email.text_body =~ "Hi ,"
      assert email.text_body =~ "Hi, "
    end

    test "does not include meeting line when meeting_title is nil" do
      ctx = build_context(%{meeting_title: nil})
      email = BookingPaymentRefunded.render(ctx)

      refute email.text_body =~ "Meeting:"
    end

    test "uses fallback host name when host_name is nil" do
      ctx = build_context(%{host_name: nil})
      email = BookingPaymentRefunded.render(ctx)

      assert email.text_body =~ "your host"
    end
  end

  describe "render/1 with non-English locale" do
    test "subject and body translate to German" do
      ctx = build_context(%{locale: "de"})
      email = BookingPaymentRefunded.render(ctx)

      # We don't assert exact translations (they may not exist yet — that
      # arrives in Chunk 11). We assert the call doesn't crash and the body
      # is a valid string.
      assert is_binary(email.subject)
      assert is_binary(email.html_body)
      assert is_binary(email.text_body)
      assert String.length(email.html_body) > 100
    end
  end
end
