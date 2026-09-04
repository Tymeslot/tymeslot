defmodule Tymeslot.Workers.ZoomScopeAuditWorkerTest do
  @moduledoc """
  Drives the nightly audit that finds Zoom grants predating a scope Tymeslot
  needs, before the user discovers the gap by rescheduling a booking.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.ZoomScopeAuditWorker

  # Everything Tymeslot currently asks Zoom for.
  @current_grant "meeting:write:meeting meeting:delete:meeting meeting:read:meeting user:read:user"

  # A grant issued before `meeting:delete:meeting` was requested: short of a
  # scope Tymeslot does ask for, so reconnecting genuinely restores it.
  @pre_delete_grant "meeting:write:meeting meeting:read:meeting user:read:user"

  describe "perform/1" do
    test "flags a stale grant and tells the user what they have lost" do
      integration = zoom_integration(oauth_scope: @pre_delete_grant)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth
      assert reloaded.sync_error =~ "cancel meetings"
      assert reloaded.sync_error =~ "reconnect"
    end

    test "emails the account owner rather than waiting for them to visit the dashboard" do
      integration = zoom_integration(oauth_scope: @pre_delete_grant)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_reauth_notification",
          "user_id" => integration.user_id,
          "integration_id" => integration.id,
          "integration_type" => "video"
        }
      )
    end

    test "does not ask a user to reconnect for a scope Tymeslot never requests" do
      # `meeting:update:meeting` is absent from every grant because the Zoom app
      # is not approved for it. Reconnecting would produce exactly the same
      # scopes, so sending the user round that loop would be a lie.
      integration = zoom_integration(oauth_scope: @current_grant)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute Repo.reload!(integration).needs_reauth
      refute_enqueued(worker: EmailWorker)
    end

    test "reports the blocked integrations so the gap is not silent" do
      zoom_integration(oauth_scope: @current_grant)

      log =
        capture_log(fn ->
          assert :ok = perform_job(ZoomScopeAuditWorker, %{})
        end)

      assert log =~ "users cannot fix this by reconnecting"
    end

    test "still flags a stale grant that is also short an unrequestable scope" do
      # The pre-delete grant lacks `meeting:update:meeting` too. The gap the
      # user can close must not be masked by the one they cannot.
      integration = zoom_integration(oauth_scope: @pre_delete_grant)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      assert Repo.reload!(integration).needs_reauth
    end

    test "leaves a grant holding every requested scope alone" do
      integration = zoom_integration(oauth_scope: @current_grant)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute Repo.reload!(integration).needs_reauth
      refute_enqueued(worker: EmailWorker)
    end

    test "leaves a classic coarse-scoped grant alone" do
      # Classic apps hold one `meeting:write` covering create, update and
      # delete, so they are not short of anything.
      integration = zoom_integration(oauth_scope: "meeting:write meeting:read user:read")

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute Repo.reload!(integration).needs_reauth
      refute_enqueued(worker: EmailWorker)
    end

    test "does not re-notify an integration already flagged" do
      # The user has the badge and the email already; a second one would say
      # nothing new about a problem they are looking at.
      zoom_integration(oauth_scope: @pre_delete_grant, needs_reauth: true)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute_enqueued(worker: EmailWorker)
    end

    test "ignores integrations belonging to other providers" do
      integration = insert(:video_integration, provider: "mirotalk", oauth_scope: nil)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute Repo.reload!(integration).needs_reauth
    end

    test "ignores a deactivated Zoom integration" do
      integration = zoom_integration(oauth_scope: @pre_delete_grant, is_active: false)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute Repo.reload!(integration).needs_reauth
    end

    test "flags a grant with no recorded scope at all" do
      # Rows predating scope recording can do nothing at all; a missing scope
      # string must not read as an unrestricted one.
      integration = zoom_integration(oauth_scope: nil)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      assert Repo.reload!(integration).needs_reauth
    end
  end

  defp zoom_integration(attrs) do
    insert(:video_integration, [provider: "zoom", name: "Zoom"] ++ attrs)
  end
end
