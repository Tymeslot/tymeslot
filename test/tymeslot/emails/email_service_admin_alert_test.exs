defmodule Tymeslot.Emails.EmailServiceAdminAlertTest do
  use Tymeslot.DataCase, async: false
  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailService

  defmodule RaisingAdminAlerts do
    @spec send_alert(any(), any(), any()) :: no_return()
    def send_alert(_event, _metadata, _opts) do
      raise "admin alert failure"
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

    assert match?({:ok, _}, result)
  end
end
