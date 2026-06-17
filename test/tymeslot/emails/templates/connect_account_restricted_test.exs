defmodule Tymeslot.Emails.Templates.ConnectAccountRestrictedTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :payments

  alias Tymeslot.Emails.Templates.ConnectAccountRestricted
  alias Tymeslot.Emails.Templates.ConnectAccountRestricted.RestrictionContext

  defp build_context(overrides \\ %{}) do
    defaults = %{
      host_email: "host@example.com",
      host_name: "Bob Host",
      disabled_reason: "requirements.past_due",
      previous_disabled_reason: nil,
      charges_enabled: false,
      payouts_enabled: false,
      dashboard_url: "https://dashboard.stripe.com/"
    }

    struct!(RestrictionContext, Map.merge(defaults, overrides))
  end

  describe "render/1" do
    test "delivers to the host" do
      email = ConnectAccountRestricted.render(build_context())
      assert email.to == [{"Bob Host", "host@example.com"}]
    end

    test "subject is concise and host-facing" do
      email = ConnectAccountRestricted.render(build_context())
      assert email.subject =~ "Stripe account restricted"
    end

    test "marks the email as high priority" do
      email = ConnectAccountRestricted.render(build_context())
      assert {"X-Priority", "1"} in email.headers
    end

    test "html body shows the reason and dashboard link" do
      email = ConnectAccountRestricted.render(build_context())

      assert email.html_body =~ "requirements.past_due"
      assert email.html_body =~ "Charges enabled: no"
      assert email.html_body =~ "Payouts enabled: no"
      assert email.html_body =~ "https://dashboard.stripe.com/"
    end

    test "text body covers the same details" do
      email = ConnectAccountRestricted.render(build_context())

      assert email.text_body =~ "STRIPE ACCOUNT RESTRICTED"
      assert email.text_body =~ "requirements.past_due"
      assert email.text_body =~ "Charges enabled: no"
      assert email.text_body =~ "https://dashboard.stripe.com/"
    end

    test "is English-only" do
      email = ConnectAccountRestricted.render(build_context())

      # English-only — no localised strings expected
      assert email.text_body =~ "RESTORE YOUR ACCOUNT"
    end

    test "falls back to a generic stage subtitle when reason is blank" do
      email = ConnectAccountRestricted.render(build_context(%{disabled_reason: ""}))

      assert email.html_body =~ "Account restricted"
    end

    test "delivers to the bare email when host_name is nil (no placeholder name)" do
      email = ConnectAccountRestricted.render(build_context(%{host_name: nil}))
      assert email.to == [{"", "host@example.com"}]
      assert email.html_body =~ "Hi there —"
    end

    test "omits charges/payouts lines when nil" do
      ctx = build_context(%{charges_enabled: nil, payouts_enabled: nil})
      email = ConnectAccountRestricted.render(ctx)

      refute email.text_body =~ "Charges enabled:"
      refute email.text_body =~ "Payouts enabled:"
    end
  end
end
