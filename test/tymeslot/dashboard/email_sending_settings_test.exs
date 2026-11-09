defmodule Tymeslot.Dashboard.EmailSendingSettingsTest do
  @moduledoc "Verifies that settings data is loaded after authentication and remains owner scoped."

  use Tymeslot.DataCase, async: false

  @moduletag :dashboard
  @moduletag :security

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.EmailSending.Settings
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Security.Encryption

  setup do
    with_config(:tymeslot, user_smtp_enabled: true)
    %{user: insert(:user)}
  end

  test "loads only the authenticated owner's redacted settings", %{user: user} do
    own = settings(user, "own@example.com")
    other = insert(:user)
    settings(other, "other@example.com")

    assert %{smtp_settings: %Settings{} = view, smtp_settings_loaded: true} =
             DashboardContext.get_dashboard_data_for_action(user, "Etc/UTC", :settings)

    assert view.id == own.id
    assert view.from_address == "own@example.com"
    refute Map.has_key?(view, :password_encrypted)
    refute Map.has_key?(view, :username_encrypted)
    refute Map.has_key?(view, :password)
    refute Map.has_key?(view, :username)
  end

  test "a user without settings gets an explicit loaded empty state", %{user: user} do
    assert %{smtp_settings: nil, smtp_settings_loaded: true} =
             DashboardContext.get_dashboard_data_for_action(user, "Etc/UTC", :settings)
  end

  test "disabled features, unrelated actions and unauthenticated inputs never fetch SMTP data", %{
    user: user
  } do
    handler = {__MODULE__, self()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          if metadata.query =~ "user_smtp_settings", do: send(pid, :smtp_query)
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert DashboardContext.get_dashboard_data_for_action(nil, "Etc/UTC", :settings) == %{}

    assert DashboardContext.get_dashboard_data_for_action(%UserSchema{}, "Etc/UTC", :settings) ==
             %{}

    assert DashboardContext.get_dashboard_data_for_action(
             %UserSchema{id: 9_223_372_036_854_775_808},
             "Etc/UTC",
             :settings
           ) == %{}

    assert DashboardContext.get_dashboard_data_for_action(%{id: user.id}, "Etc/UTC", :settings) ==
             %{}

    assert DashboardContext.get_dashboard_data_for_action(user, "Etc/UTC", :integrations) == %{}

    with_config(:tymeslot, user_smtp_enabled: false)
    assert DashboardContext.get_dashboard_data_for_action(user, "Etc/UTC", :settings) == %{}
    refute_received :smtp_query
  end

  defp settings(user, from_address) do
    Repo.insert!(%UserSmtpSettingsSchema{
      user_id: user.id,
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("smtp-owner"),
      password_encrypted: Encryption.encrypt("smtp-password"),
      from_address: from_address,
      from_name: "Booking team"
    })
  end
end
