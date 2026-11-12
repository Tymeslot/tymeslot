defmodule Tymeslot.Integrations.HealthCheck.ResponseHandlerPasswordRejectionTest do
  @moduledoc """
  The health probe holds a password-based (CalDAV-family) calendar's rejected
  credentials to `ReauthHandling.password_rejection_threshold/0` consecutive
  hard failures before flagging it, like the sync worker does. OAuth calendars
  keep flagging on the first refused grant.
  """
  # async: false — the threshold is application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.HealthCheck.ResponseHandler

  setup do
    with_config(:tymeslot, :caldav_reauth_after_failed_cycles, 3)
    :ok
  end

  defp probe_failed(integration, hard_failures, reason) do
    state = %{Monitor.initial_state() | consecutive_hard_failures: hard_failures}

    ResponseHandler.handle_check_result(
      :calendar,
      integration,
      {:no_change, :healthy, :healthy},
      state,
      {:error, reason}
    )

    {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
    updated
  end

  for provider <- ["caldav", "radicale", "nextcloud"] do
    test "#{provider}: a first rejected probe does not flag" do
      integration =
        insert(:calendar_integration, provider: unquote(provider), needs_reauth: false)

      refute probe_failed(integration, 1, :invalid_credentials).needs_reauth
    end

    test "#{provider}: the rejection that reaches the threshold flags" do
      integration =
        insert(:calendar_integration, provider: unquote(provider), needs_reauth: false)

      refute probe_failed(integration, 2, :unauthorized).needs_reauth
      assert probe_failed(integration, 3, :unauthorized).needs_reauth
    end
  end

  test "an OAuth calendar is flagged on the first refused grant" do
    integration = insert(:calendar_integration, provider: "google", needs_reauth: false)

    assert probe_failed(integration, 1, "Token refresh failed: invalid_grant").needs_reauth
  end
end
