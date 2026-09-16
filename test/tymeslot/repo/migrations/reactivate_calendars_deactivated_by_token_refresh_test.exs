defmodule Tymeslot.Repo.Migrations.ReactivateCalendarsDeactivatedByTokenRefreshTest do
  @moduledoc """
  The token refresh job used to deactivate an integration whose grant the
  provider refused, which left it out of every path that could flag it for
  reconnection. What matters is that the repair reaches exactly the rows that
  job wrote, and that a reactivated row then meets the reconnection flow.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :migrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Test.MigrationRunner
  alias Tymeslot.Workers.EmailWorker

  @version 20_260_916_121_729

  @stranded_error "Google integration failed during token refresh: " <>
                    "unauthorized: Token refresh failed (PERMANENT)"

  setup :verify_on_exit!

  defp reload(integration), do: Repo.get!(CalendarIntegrationSchema, integration.id)

  defp stranded(attrs \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [provider: "google", is_active: false, needs_reauth: false, sync_error: @stranded_error],
        attrs
      )
    )
  end

  test "reactivates a Google or Outlook integration the refresh job deactivated" do
    google = stranded()

    outlook =
      stranded(
        provider: "outlook",
        sync_error:
          "Outlook integration failed during token refresh: " <>
            "unauthorized: Token refresh failed: invalid_grant (PERMANENT)"
      )

    MigrationRunner.replay!(@version)

    assert reload(google).is_active
    assert reload(outlook).is_active
  end

  test "leaves integrations the refresh job did not strand as they were" do
    paused = stranded(sync_error: nil)
    already_flagged = stranded(needs_reauth: true)

    transient =
      stranded(sync_error: "Google integration failed during token refresh: timeout (RETRYABLE)")

    other_provider =
      stranded(
        provider: "caldav",
        sync_error: "Caldav integration failed during token refresh: x (PERMANENT)"
      )

    MigrationRunner.replay!(@version)

    refute reload(paused).is_active
    refute reload(already_flagged).is_active
    refute reload(transient).is_active
    refute reload(other_provider).is_active
  end

  # The migration only undoes the deactivation; the owner is told by the path
  # the job now takes. This is the reason it must not set `needs_reauth`
  # itself: an already-flagged integration is never emailed.
  test "a reactivated integration is flagged and its owner emailed on the next refused refresh" do
    user = insert(:user)

    integration =
      stranded(
        user: user,
        token_expires_at: DateTime.add(DateTime.utc_now(:second), -1, :hour),
        refresh_token: "rt-123"
      )

    MigrationRunner.replay!(@version)

    expect(GoogleCalendarAPIMock, :refresh_token, fn _integration ->
      {:error, :unauthorized, "Token refresh failed: invalid_grant"}
    end)

    assert {:discard, _reason} =
             TokenRefreshJob.perform(%Oban.Job{args: %{"integration_id" => integration.id}})

    updated = reload(integration)
    assert updated.needs_reauth
    assert updated.sync_error == ReauthHandling.reauth_error_message(:expired_grant)

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_integration_reauth_notification", "user_id" => user.id}
    )
  end
end
