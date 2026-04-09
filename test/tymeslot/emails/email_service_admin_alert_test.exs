defmodule Tymeslot.Emails.EmailServiceAdminAlertTest do
  use Tymeslot.DataCase, async: false
  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailService

  defmodule RaisingAdminAlerts do
    @spec send_alert(any(), any()) :: no_return()
    def send_alert(_event, _metadata) do
      raise "admin alert failure"
    end
  end

  # Note: Swoosh.TestAssertions.assert_email_sent/1 is not used here because
  # EmailService.deliver/1 runs inside CircuitBreaker.call/2, which executes the
  # delivery function inside a GenServer. Swoosh's test adapter sends the
  # {:email, email} message to whichever process calls Mailer.deliver/1 — in
  # this case the circuit breaker GenServer, not the test process. Content
  # assertions are covered by Tymeslot.Emails.Templates.AdminAlertTest instead.
  describe "send_admin_alert/5" do
    test "happy path: returns {:ok, _} for a :warning alert with metadata" do
      assert {:ok, _} =
               EmailService.send_admin_alert(
                 "ops@example.com",
                 "Webhook",
                 :warning,
                 "Unhandled webhook event received",
                 %{"event_id" => "evt_001", "event_type" => "charge.failed"}
               )
    end

    test "returns {:ok, _} for an :error severity alert" do
      assert {:ok, _} =
               EmailService.send_admin_alert(
                 "ops@example.com",
                 "Security",
                 :error,
                 "Suspicious login attempt detected",
                 %{"user_id" => "42", "ip" => "1.2.3.4"}
               )
    end

    test "returns {:ok, _} for an :info severity alert" do
      assert {:ok, _} =
               EmailService.send_admin_alert(
                 "ops@example.com",
                 "Payments",
                 :info,
                 "Refund processed successfully",
                 %{"refund_id" => "re_001"}
               )
    end

    test "returns {:ok, _} with empty metadata" do
      assert {:ok, _} =
               EmailService.send_admin_alert(
                 "ops@example.com",
                 "General",
                 :warning,
                 "Alert with no metadata",
                 %{}
               )
    end

    test "returns {:ok, _} for a :warning alert with rich metadata" do
      assert {:ok, _} =
               EmailService.send_admin_alert(
                 "ops@example.com",
                 "General",
                 :warning,
                 "Test alert with metadata",
                 %{"order_id" => "ord_999", "amount" => "100"}
               )
    end
  end

  test "calendar sync error still sends email when admin alert fails" do
    original_alerts = Application.get_env(:tymeslot, :admin_alerts_impl)
    Application.put_env(:tymeslot, :admin_alerts_impl, RaisingAdminAlerts)

    on_exit(fn ->
      if is_nil(original_alerts) do
        Application.delete_env(:tymeslot, :admin_alerts_impl)
      else
        Application.put_env(:tymeslot, :admin_alerts_impl, original_alerts)
      end
    end)

    meeting = build(:meeting)

    result = EmailService.send_calendar_sync_error(meeting, :test_error)

    assert {:ok, _} = result
  end
end
