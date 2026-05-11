defmodule Tymeslot.Emails.Templates.ChargeDisputeOpenedTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :payments

  alias Tymeslot.Emails.Templates.ChargeDisputeOpened
  alias Tymeslot.Emails.Templates.ChargeDisputeOpened.DisputeContext

  defp build_context(overrides \\ %{}) do
    defaults = %{
      host_email: "host@example.com",
      host_name: "Bob Host",
      amount_cents: 5000,
      currency: "eur",
      attendee_name: "Alice",
      attendee_email: "alice@example.com",
      meeting_title: "Discovery Call",
      stripe_charge_id: "ch_DISPUTED",
      reason: "fraudulent"
    }

    struct!(DisputeContext, Map.merge(defaults, overrides))
  end

  describe "render/1" do
    test "delivers to the host" do
      email = ChargeDisputeOpened.render(build_context())
      assert email.to == [{"Bob Host", "host@example.com"}]
    end

    test "subject names the disputed amount" do
      email = ChargeDisputeOpened.render(build_context())
      assert email.subject =~ "Stripe dispute opened"
      assert email.subject =~ "€50.00"
    end

    test "marks the email as high priority via X-Priority header" do
      email = ChargeDisputeOpened.render(build_context())
      assert {"X-Priority", "1"} in email.headers
    end

    test "html body shows the dispute amount, attendee, meeting and reason" do
      email = ChargeDisputeOpened.render(build_context())

      assert email.html_body =~ "€50.00"
      assert email.html_body =~ "Alice"
      assert email.html_body =~ "alice@example.com"
      assert email.html_body =~ "Discovery Call"
      assert email.html_body =~ "ch_DISPUTED"
      assert email.html_body =~ "fraudulent"
      assert email.html_body =~ "https://dashboard.stripe.com/disputes"
    end

    test "text body covers the same details" do
      email = ChargeDisputeOpened.render(build_context())

      assert email.text_body =~ "STRIPE DISPUTE OPENED"
      assert email.text_body =~ "€50.00"
      assert email.text_body =~ "Alice"
      assert email.text_body =~ "Discovery Call"
      assert email.text_body =~ "https://dashboard.stripe.com/disputes"
    end

    test "is English-only — host emails do not localise" do
      email = ChargeDisputeOpened.render(build_context())

      assert email.text_body =~ "WHAT HAPPENS NEXT"
      assert email.html_body =~ "What happens next"
    end

    test "omits attendee/meeting/reason lines when fields are nil" do
      ctx =
        build_context(%{
          attendee_name: nil,
          attendee_email: nil,
          meeting_title: nil,
          stripe_charge_id: nil,
          reason: nil
        })

      email = ChargeDisputeOpened.render(ctx)

      refute email.text_body =~ "Attendee:"
      refute email.text_body =~ "Meeting:"
      refute email.text_body =~ "Stated reason:"
      refute email.text_body =~ "Stripe charge:"
    end

    test "falls back gracefully when host_name is nil" do
      email = ChargeDisputeOpened.render(build_context(%{host_name: nil}))
      assert email.to == [{"there", "host@example.com"}]
    end

    test "omits attendee email line in both bodies when attendee_email is nil (anonymised payment)" do
      email = ChargeDisputeOpened.render(build_context(%{attendee_email: nil, attendee_name: nil}))

      refute email.html_body =~ "Attendee email:"
      refute email.html_body =~ "@deleted.local"
      refute email.text_body =~ "Attendee email:"
      refute email.text_body =~ "@deleted.local"
    end
  end
end
