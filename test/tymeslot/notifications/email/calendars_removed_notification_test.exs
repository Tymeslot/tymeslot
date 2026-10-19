defmodule Tymeslot.Notifications.Email.CalendarsRemovedNotificationTest do
  @moduledoc """
  The email job telling an owner that their calendar server stopped listing
  calendars Tymeslot used.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Notifications.Email.IntegrationEmails
  alias Tymeslot.Notifications.EmailHandlers

  setup :verify_on_exit!

  describe "handle_calendars_removed_notification/1" do
    test "sends the owner the calendars named in the job" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      expect(EmailServiceMock, :send_calendars_removed_notification, fn sent_user,
                                                                        sent_integration,
                                                                        names ->
        assert sent_user.id == user.id
        assert sent_integration.id == integration.id
        assert names == ["Work", "Team"]
        {:ok, "sent"}
      end)

      assert :ok =
               execute_calendars_removed_notification(user.id, integration.id, ["Work", "Team"])
    end

    # A failed send is retried, keeping what the delivery layer said: an open
    # circuit is waited out rather than counted as an ordinary failure.
    @tag :capture_log
    test "returns a failed send as an error, so the job is retried" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      expect(EmailServiceMock, :send_calendars_removed_notification, fn _user, _int, _names ->
        {:error, :circuit_open}
      end)

      assert {:error, :circuit_open} =
               execute_calendars_removed_notification(user.id, integration.id, ["Work"])

      expect(EmailServiceMock, :send_calendars_removed_notification, fn _user, _int, _names ->
        {:error, :smtp_failed}
      end)

      assert {:error, "Failed to send notification"} =
               execute_calendars_removed_notification(user.id, integration.id, ["Work"])
    end

    test "discards, as expected, when the integration was deleted before the job ran" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      Repo.delete!(integration)

      expect(EmailServiceMock, :send_calendars_removed_notification, 0, fn _user, _int, _names ->
        {:ok, "sent"}
      end)

      assert {:discard, reason} =
               execute_calendars_removed_notification(user.id, integration.id, ["Work"])

      assert IntegrationEmails.expected_discard?(reason)
    end
  end

  defp execute_calendars_removed_notification(user_id, integration_id, names) do
    EmailHandlers.execute_email_action("send_calendars_removed_notification", %{
      "user_id" => user_id,
      "integration_id" => integration_id,
      "calendar_names" => names
    })
  end
end
