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

  # Both uniqueness indexes on the table are predicated on `is_active = true`,
  # so reactivating a row moves it into one of them: the `(user_id, provider)`
  # index when its account id is NULL, the account index otherwise. The
  # application refuses such a reactivation (`toggle_active/1`); the migration
  # has to skip it, because a raised unique_violation here fails the migration
  # and stops the release from booting.
  describe "when reactivating would collide with an active integration" do
    test "leaves a stranded NULL-account row inactive beside an active NULL-account row" do
      user = insert(:user)

      active =
        insert(:calendar_integration, user: user, provider: "google", provider_account_id: nil)

      collides = stranded(user: user, provider_account_id: nil)

      MigrationRunner.replay!(@version)

      assert reload(active).is_active
      refute reload(collides).is_active
    end

    test "leaves a stranded row inactive when an active row has the same account" do
      user = insert(:user)

      active =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: "acct-1"
        )

      collides = stranded(user: user, provider_account_id: "acct-1")

      MigrationRunner.replay!(@version)

      assert reload(active).is_active
      refute reload(collides).is_active
    end

    test "reactivates exactly one of two stranded rows for the same account" do
      user = insert(:user)
      first = stranded(user: user, provider_account_id: "acct-1")
      second = stranded(user: user, provider_account_id: "acct-1")

      MigrationRunner.replay!(@version)

      assert Enum.count([reload(first), reload(second)], & &1.is_active) == 1
    end

    test "reactivates exactly one of two stranded NULL-account rows" do
      user = insert(:user)
      first = stranded(user: user, provider_account_id: nil)
      second = stranded(user: user, provider_account_id: nil)

      MigrationRunner.replay!(@version)

      assert Enum.count([reload(first), reload(second)], & &1.is_active) == 1
    end

    test "a different account of the same provider does not block reactivation" do
      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "google", provider_account_id: "acct-1")
      other_account = stranded(user: user, provider_account_id: "acct-2")

      MigrationRunner.replay!(@version)

      assert reload(other_account).is_active
    end
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
