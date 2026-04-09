defmodule Tymeslot.Emails.Templates.AdminAlertTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.AdminAlert

  describe "render/4" do
    test "includes the message in the HTML output" do
      html = AdminAlert.render("Webhook", :warning, "Unhandled webhook event received", %{})

      assert html =~ "Unhandled webhook event received"
    end

    test "includes the category in the HTML output" do
      html = AdminAlert.render("Payments", :error, "Payment failed", %{})

      assert html =~ "Payments"
    end

    test "renders a valid HTML document with substantial content" do
      html = AdminAlert.render("General", :warning, "Test alert", %{})

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "empty metadata renders 'No additional context' placeholder" do
      html = AdminAlert.render("General", :info, "Informational notice", %{})

      assert html =~ "No additional context"
    end

    test "non-empty metadata renders key-value pairs in a table" do
      html =
        AdminAlert.render("Webhook", :warning, "Alert with context", %{
          "event_id" => "evt_001",
          "event_type" => "charge.failed"
        })

      assert html =~ "event_id"
      assert html =~ "evt_001"
      assert html =~ "event_type"
      assert html =~ "charge.failed"
    end

    test "HTML-escapes metadata values containing '<' and '>' characters" do
      html =
        AdminAlert.render("Security", :error, "XSS test", %{
          "payload" => "<script>alert('xss')</script>"
        })

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "HTML-escapes metadata values containing '&'" do
      html =
        AdminAlert.render("General", :warning, "Ampersand test", %{
          "query" => "foo & bar"
        })

      refute html =~ "foo & bar"
      assert html =~ "foo &amp; bar"
    end

    test "HTML-escapes metadata values containing '\"'" do
      html =
        AdminAlert.render("General", :warning, "Quote test", %{
          "value" => ~s(say "hello")
        })

      assert html =~ "&quot;hello&quot;"
    end
  end

  describe "render_text/4" do
    test "includes the message in the plain-text output" do
      text = AdminAlert.render_text("Webhook", :warning, "Unhandled webhook received", %{})

      assert text =~ "Unhandled webhook received"
    end

    test "includes the severity in the plain-text output" do
      text = AdminAlert.render_text("General", :error, "Critical failure", %{})

      assert text =~ "error"
    end

    test "includes the category in the plain-text output" do
      text = AdminAlert.render_text("Payments", :info, "Refund processed", %{})

      assert text =~ "Payments"
    end

    test "metadata keys appear in the plain-text output" do
      text =
        AdminAlert.render_text("General", :warning, "Alert with context", %{
          "order_id" => "ord_999",
          "amount" => "100"
        })

      assert text =~ "order_id"
      assert text =~ "ord_999"
    end

    test "empty metadata renders '(none)' placeholder" do
      text = AdminAlert.render_text("General", :info, "No context", %{})

      assert text =~ "(none)"
    end

    test "returns a valid binary with the standard header" do
      text = AdminAlert.render_text("General", :warning, "Test", %{})

      assert is_binary(text)
      assert text =~ "TYMESLOT ADMIN ALERT"
    end
  end
end
