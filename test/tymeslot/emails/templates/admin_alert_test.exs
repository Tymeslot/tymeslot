defmodule Tymeslot.Emails.Templates.AdminAlertTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.AdminAlert

  describe "render/5" do
    test "goes to the operator, under a subject carrying the severity" do
      email = AdminAlert.render("ops@example.com", "Payments", :warning, "Payment failed", %{})

      assert email.to == [{"Tymeslot Operator", "ops@example.com"}]
      assert email.subject == "[WARNING] Tymeslot: Payments"
    end

    test "marks an error with the warning sign" do
      email = AdminAlert.render("ops@example.com", "Payments", :error, "Payment failed", %{})

      assert email.subject == "[ERROR] ⚠️ Tymeslot: Payments"
    end

    test "stays in English whatever the process locale" do
      email =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          AdminAlert.render("ops@example.com", "General", :info, "Notice", %{})
        end)

      assert email.text_body =~ "TYMESLOT ADMIN ALERT"
      assert email.html_body =~ "No additional context"
    end
  end

  describe "the HTML part" do
    test "includes the message in the HTML output" do
      html =
        AdminAlert.render(
          "ops@example.com",
          "Webhook",
          :warning,
          "Unhandled webhook event received",
          %{}
        ).html_body

      assert html =~ "Unhandled webhook event received"
    end

    test "includes the category in the HTML output" do
      html =
        AdminAlert.render("ops@example.com", "Payments", :error, "Payment failed", %{}).html_body

      assert html =~ "Payments"
    end

    test "renders a complete HTML document around the alert" do
      html =
        AdminAlert.render("ops@example.com", "General", :warning, "Test alert", %{}).html_body

      assert html =~ "<!doctype html>"
      assert html =~ "<title>Tymeslot Admin Alert</title>"
      assert html =~ "Test alert"
      assert String.ends_with?(String.trim(html), "</html>")
    end

    test "empty metadata renders 'No additional context' placeholder" do
      html =
        AdminAlert.render("ops@example.com", "General", :info, "Informational notice", %{}).html_body

      assert html =~ "No additional context"
    end

    test "non-empty metadata renders key-value pairs in a table" do
      html =
        AdminAlert.render("ops@example.com", "Webhook", :warning, "Alert with context", %{
          "event_id" => "evt_001",
          "event_type" => "charge.failed"
        }).html_body

      assert html =~ "event_id"
      assert html =~ "evt_001"
      assert html =~ "event_type"
      assert html =~ "charge.failed"
    end

    test "HTML-escapes metadata values containing '<' and '>' characters" do
      html =
        AdminAlert.render("ops@example.com", "Security", :error, "XSS test", %{
          "payload" => "<script>alert('xss')</script>"
        }).html_body

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "HTML-escapes metadata values containing '&'" do
      html =
        AdminAlert.render("ops@example.com", "General", :warning, "Ampersand test", %{
          "query" => "foo & bar"
        }).html_body

      refute html =~ "foo & bar"
      assert html =~ "foo &amp; bar"
    end

    test "HTML-escapes metadata values containing '\"'" do
      html =
        AdminAlert.render("ops@example.com", "General", :warning, "Quote test", %{
          "value" => ~s(say "hello")
        }).html_body

      assert html =~ "&quot;hello&quot;"
    end
  end

  describe "the plain text part" do
    test "includes the message in the plain-text output" do
      text =
        AdminAlert.render(
          "ops@example.com",
          "Webhook",
          :warning,
          "Unhandled webhook received",
          %{}
        ).text_body

      assert text =~ "Unhandled webhook received"
    end

    test "includes the severity in the plain-text output" do
      text =
        AdminAlert.render("ops@example.com", "General", :error, "Critical failure", %{}).text_body

      assert text =~ "error"
    end

    test "includes the category in the plain-text output" do
      text =
        AdminAlert.render("ops@example.com", "Payments", :info, "Refund processed", %{}).text_body

      assert text =~ "Payments"
    end

    test "metadata keys appear in the plain-text output" do
      text =
        AdminAlert.render("ops@example.com", "General", :warning, "Alert with context", %{
          "order_id" => "ord_999",
          "amount" => "100"
        }).text_body

      assert text =~ "order_id"
      assert text =~ "ord_999"
    end

    test "empty metadata renders '(none)' placeholder" do
      text = AdminAlert.render("ops@example.com", "General", :info, "No context", %{}).text_body

      assert text =~ "(none)"
    end

    test "opens with the standard header" do
      text = AdminAlert.render("ops@example.com", "General", :warning, "Test", %{}).text_body

      assert text =~ "TYMESLOT ADMIN ALERT"
      assert text =~ "Test"
    end
  end
end
