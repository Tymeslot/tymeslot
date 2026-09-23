defmodule Tymeslot.Workers.ZoomScopeAuditWorkerTest do
  @moduledoc """
  Drives the nightly audit that finds Zoom grants predating a scope Tymeslot
  needs, before the user discovers the gap by rescheduling a booking.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.ZoomScopeAuditWorker

  # Everything Tymeslot currently asks Zoom for.
  @current_grant "meeting:write:meeting meeting:update:meeting meeting:delete:meeting " <>
                   "meeting:read:meeting user:read:user"

  # A grant issued before `meeting:update:meeting` was requested: short of a
  # scope Tymeslot does ask for, so reconnecting genuinely restores it.
  @pre_update_grant "meeting:write:meeting meeting:delete:meeting meeting:read:meeting user:read:user"

  describe "perform/1" do
    test "flags a stale grant and tells the user what they have lost" do
      integration = zoom_integration(oauth_scope: @pre_update_grant)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth
      assert reloaded.sync_error =~ "reschedule meetings"
      assert reloaded.sync_error =~ "reconnect"
    end

    test "emails the account owner rather than waiting for them to visit the dashboard" do
      integration = zoom_integration(oauth_scope: @pre_update_grant)

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

    test "names the earliest operation the grant cannot perform" do
      # Short of both the update and the delete scope: rescheduling comes first
      # in a meeting's lifecycle, so that is what the user is told they lost.
      integration =
        zoom_integration(oauth_scope: "meeting:write:meeting meeting:read:meeting user:read:user")

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      assert Repo.reload!(integration).sync_error =~ "reschedule meetings"
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
      zoom_integration(oauth_scope: @pre_update_grant, needs_reauth: true)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute_enqueued(worker: EmailWorker)
    end

    test "ignores integrations belonging to other providers" do
      integration = insert(:video_integration, provider: "mirotalk", oauth_scope: nil)

      assert :ok = perform_job(ZoomScopeAuditWorker, %{})

      refute Repo.reload!(integration).needs_reauth
    end

    test "ignores a deactivated Zoom integration" do
      integration = zoom_integration(oauth_scope: @pre_update_grant, is_active: false)

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
