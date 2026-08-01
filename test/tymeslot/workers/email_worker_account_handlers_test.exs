defmodule Tymeslot.Workers.EmailWorkerAccountHandlersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  describe "handle_email_change_verification/1" do
    test "successfully sends verification email to new address" do
      user = insert(:user)
      new_email = "new@example.com"

      expect(EmailServiceMock, :send_email_change_verification, fn _user, ^new_email, _url ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_email_change_verification", %{
                 "user_id" => user.id,
                 "new_email" => new_email,
                 "verification_url" => "https://example.com/verify/token123"
               })
    end

    test "discards job when user is not found" do
      assert {:discard, "User not found"} =
               EmailWorkerHandlers.execute_email_action("send_email_change_verification", %{
                 "user_id" => 999_999,
                 "new_email" => "new@example.com",
                 "verification_url" => "https://example.com/verify/token"
               })
    end

    test "returns error when email service fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_verification, fn _user, _new_email, _url ->
        {:error, "delivery failed"}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_email_change_verification", %{
                 "user_id" => user.id,
                 "new_email" => "new@example.com",
                 "verification_url" => "https://example.com/verify/token"
               })
    end
  end

  describe "handle_email_change_notification/1" do
    test "successfully sends security notification to old address" do
      user = insert(:user)
      new_email = "new@example.com"

      expect(EmailServiceMock, :send_email_change_notification, fn _user, ^new_email ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_email_change_notification", %{
                 "user_id" => user.id,
                 "new_email" => new_email
               })
    end

    test "discards job when user is not found" do
      assert {:discard, "User not found"} =
               EmailWorkerHandlers.execute_email_action("send_email_change_notification", %{
                 "user_id" => 999_999,
                 "new_email" => "new@example.com"
               })
    end

    test "returns error when email service fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_notification, fn _user, _new_email ->
        {:error, "delivery failed"}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_email_change_notification", %{
                 "user_id" => user.id,
                 "new_email" => "new@example.com"
               })
    end
  end

  describe "handle_email_change_confirmations/1" do
    test "successfully sends confirmations to both old and new addresses" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_confirmations, fn _user,
                                                                    "old@example.com",
                                                                    "new@example.com" ->
        {{:ok, "sent"}, {:ok, "sent"}}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_email_change_confirmations", %{
                 "user_id" => user.id,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end

    test "discards job when user is not found" do
      assert {:discard, "User not found"} =
               EmailWorkerHandlers.execute_email_action("send_email_change_confirmations", %{
                 "user_id" => 999_999,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end

    test "returns error when second delivery fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_confirmations, fn _user, _old, _new ->
        {{:ok, "sent"}, {:error, "delivery failed"}}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_email_change_confirmations", %{
                 "user_id" => user.id,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end

    test "returns error when first delivery fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_confirmations, fn _user, _old, _new ->
        {{:error, "delivery failed"}, {:ok, "sent"}}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_email_change_confirmations", %{
                 "user_id" => user.id,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end
  end

  describe "handle_integration_paused_notification/1" do
    test "happy path: returns :ok when user and calendar integration exist and email sends" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      expect(EmailServiceMock, :send_integration_paused_notification, fn _user,
                                                                         _integration,
                                                                         :calendar,
                                                                         14 ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => integration.id,
                   "integration_type" => "calendar",
                   "cutoff_days" => 14
                 }
               )
    end

    test "happy path: returns :ok when user and video integration exist and email sends" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      expect(EmailServiceMock, :send_integration_paused_notification, fn _user,
                                                                         _integration,
                                                                         :video,
                                                                         14 ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => integration.id,
                   "integration_type" => "video",
                   "cutoff_days" => 14
                 }
               )
    end

    test "discards when user is not found" do
      integration = insert(:calendar_integration)

      assert {:discard, "User or integration not found"} =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => 999_999,
                   "integration_id" => integration.id,
                   "integration_type" => "calendar",
                   "cutoff_days" => 14
                 }
               )
    end

    test "discards when integration is not found" do
      user = insert(:user)

      assert {:discard, "User or integration not found"} =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => 999_999,
                   "integration_type" => "calendar",
                   "cutoff_days" => 14
                 }
               )
    end

    test "returns error when email service fails" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      expect(EmailServiceMock, :send_integration_paused_notification, fn _user,
                                                                         _integration,
                                                                         _type,
                                                                         _cutoff_days ->
        {:error, "SMTP timeout"}
      end)

      assert {:error, "Failed to send notification"} =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => integration.id,
                   "integration_type" => "calendar",
                   "cutoff_days" => 14
                 }
               )
    end
  end

  describe "handle_admin_alert/1" do
    test "happy path: returns :ok and calls email service with correctly mapped args" do
      expect(EmailServiceMock, :send_admin_alert, fn recipient,
                                                     category,
                                                     severity,
                                                     message,
                                                     metadata ->
        assert recipient == "admin@example.com"
        assert category == "Webhook"
        assert severity == :warning
        assert message == "Unhandled webhook event received"
        assert metadata == %{"event_id" => "evt_001"}
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "Webhook",
                 "severity" => "warning",
                 "message" => "Unhandled webhook event received",
                 "metadata" => %{"event_id" => "evt_001"}
               })
    end

    test "error propagation: returns {:error, reason} when email service fails" do
      expect(EmailServiceMock, :send_admin_alert, fn _recipient,
                                                     _category,
                                                     _severity,
                                                     _message,
                                                     _metadata ->
        {:error, "SMTP timeout"}
      end)

      assert {:error, "Failed to deliver admin alert"} =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "Webhook",
                 "severity" => "warning",
                 "message" => "Something went wrong",
                 "metadata" => %{}
               })
    end

    test "severity fallback: unknown severity string maps to :warning" do
      expect(EmailServiceMock, :send_admin_alert, fn _recipient,
                                                     _category,
                                                     severity,
                                                     _message,
                                                     _metadata ->
        assert severity == :warning
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "General",
                 "severity" => "nonsense",
                 "message" => "Something happened",
                 "metadata" => %{}
               })
    end

    test "known severity 'info' maps to :info atom" do
      expect(EmailServiceMock, :send_admin_alert, fn _recipient,
                                                     _category,
                                                     severity,
                                                     _message,
                                                     _metadata ->
        assert severity == :info
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "General",
                 "severity" => "info",
                 "message" => "Informational notice",
                 "metadata" => %{}
               })
    end

    test "known severity 'error' maps to :error atom" do
      expect(EmailServiceMock, :send_admin_alert, fn _recipient,
                                                     _category,
                                                     severity,
                                                     _message,
                                                     _metadata ->
        assert severity == :error
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "Payments",
                 "severity" => "error",
                 "message" => "Payment processing failed",
                 "metadata" => %{"charge_id" => "ch_001"}
               })
    end
  end
end
