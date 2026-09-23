defmodule Tymeslot.Integrations.Video.NeedsReauthTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.NeedsReauth
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  describe "flag/2" do
    test "records the reason the account owner reads on the dashboard" do
      %{integration: integration, config: config} =
        setup_integration_config()

      assert :ok =
               NeedsReauth.flag(config,
                 label: "Zoom",
                 event: "zoom_missing_scope",
                 message: "Zoom is missing the permission needed to reschedule meetings."
               )

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth

      assert reloaded.sync_error ==
               "Zoom is missing the permission needed to reschedule meetings."
    end

    test "emails the owner, since the badge only reaches people who open the dashboard" do
      %{user: user, integration: integration, config: config} =
        setup_integration_config()

      assert :ok =
               NeedsReauth.flag(config,
                 label: "Zoom",
                 event: "zoom_token_revoked",
                 message: "Zoom access was revoked."
               )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_reauth_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "video"
        }
      )
    end

    test "does not email again for an integration already flagged" do
      %{config: config} = setup_integration_config()

      opts = [label: "Zoom", event: "zoom_missing_scope", message: "First diagnosis."]
      assert :ok = NeedsReauth.flag(config, opts)

      # Clear the queue rather than draining it: deleting the first job means
      # Oban's uniqueness window cannot be what suppresses a second insert, so
      # the assertion below tests the transition guard itself.
      Repo.delete_all(Oban.Job)
      refute_enqueued(worker: EmailWorker)

      assert :ok =
               NeedsReauth.flag(config,
                 label: "Zoom",
                 event: "zoom_token_revoked",
                 message: "Second diagnosis."
               )

      refute_enqueued(worker: EmailWorker)
    end

    test "still records the newer diagnosis when re-flagging" do
      %{integration: integration, config: config} =
        setup_integration_config()

      assert :ok =
               NeedsReauth.flag(config,
                 label: "Zoom",
                 event: "zoom_missing_scope",
                 message: "First diagnosis."
               )

      assert :ok =
               NeedsReauth.flag(config,
                 label: "Zoom",
                 event: "zoom_token_revoked",
                 message: "Second diagnosis."
               )

      assert Repo.reload!(integration).sync_error == "Second diagnosis."
    end

    test "does nothing when the integration cannot be found" do
      config = %{integration_id: 0, user_id: 0}

      assert :ok =
               NeedsReauth.flag(config,
                 label: "Zoom",
                 event: "zoom_missing_scope",
                 message: "Gone."
               )

      refute_enqueued(worker: EmailWorker)
    end
  end

  defp setup_integration_config do
    user = insert(:user)

    {:ok, integration} =
      VideoIntegrationQueries.create(%{
        user_id: user.id,
        name: "Zoom",
        provider: "zoom",
        access_token: "db-token",
        refresh_token: "db-refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "meeting:write:meeting"
      })

    config = %{integration_id: integration.id, user_id: user.id}

    %{user: user, integration: integration, config: config}
  end
end
