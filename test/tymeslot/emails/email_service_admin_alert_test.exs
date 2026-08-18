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

  # EmailService.deliver/1 runs inside CircuitBreaker.call/2, which executes the
  # delivery function inside a GenServer. Swoosh's test adapter delivers to
  # whichever process calls Mailer.deliver/1 — the circuit breaker, not this
  # test — so `:shared_test_process` is what makes the message observable here.
  # It is global state, hence `async: false` for the whole module.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

  describe "send_admin_alert/5" do
    test "addresses the operator and reports category, message and metadata" do
      assert {:ok, _response} =
               EmailService.send_admin_alert(
                 "ops@example.com",
                 "Webhook",
                 :warning,
                 "Unhandled webhook event received",
                 %{"event_id" => "evt_001", "event_type" => "charge.failed"}
               )

      assert_received {:email, email}
      assert email.to == [{"Tymeslot Operator", "ops@example.com"}]
      assert email.subject == "⚠️ Tymeslot Admin Alert: Webhook"
      assert email.text_body =~ "Category: Webhook"
      assert email.text_body =~ "Unhandled webhook event received"
      assert email.text_body =~ "event_id: evt_001"
      assert email.text_body =~ "event_type: charge.failed"
    end

    test "carries each severity through to the body" do
      for severity <- [:info, :warning, :error] do
        assert {:ok, _response} =
                 EmailService.send_admin_alert(
                   "ops@example.com",
                   "Security",
                   severity,
                   "Suspicious login attempt detected",
                   %{"user_id" => "42"}
                 )

        assert_received {:email, email}
        assert email.text_body =~ "Severity: #{severity}"
      end
    end

    test "marks the context section as empty when there is no metadata" do
      assert {:ok, _response} =
               EmailService.send_admin_alert(
                 "ops@example.com",
                 "General",
                 :warning,
                 "Alert with no metadata",
                 %{}
               )

      assert_received {:email, email}
      assert email.subject == "⚠️ Tymeslot Admin Alert: General"
      assert email.text_body =~ "Alert with no metadata"
      assert email.text_body =~ "(none)"
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

    assert {:ok, _response} = EmailService.send_calendar_sync_error(meeting, :test_error)

    assert_received {:email, email}
    assert [{_name, address}] = email.to
    assert address == meeting.organizer_email
    assert email.subject =~ "Calendar Sync Error"
  end
end
