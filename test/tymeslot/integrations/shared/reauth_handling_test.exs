defmodule Tymeslot.Integrations.Shared.ReauthHandlingTest do
  @moduledoc """
  Verifies the shared reauth-flagging policy: logging, persisting the flag,
  and notifying the owner once per false to true transition.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :security

  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionLabels

  describe "flag/2" do
    test "logs a warning, persists the flag, and returns :ok" do
      integration = insert(:calendar_integration, provider: "caldav")

      log =
        capture_log(fn ->
          assert :ok =
                   ReauthHandling.flag(:calendar, integration)
        end)

      assert log =~ "credentials cannot be decrypted"

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth == true
      assert reloaded.sync_error =~ "could not be decrypted"
    end

    test "reports a row that has gone instead of flagging it" do
      integration = insert(:calendar_integration, provider: "caldav")
      Repo.delete!(integration)

      log =
        capture_log(fn ->
          assert {:error, :not_found} = ReauthHandling.flag(:calendar, integration)
        end)

      assert log =~ "no longer exists"
    end

    # The decryption message above is the default because `flag/2` was built for
    # the "credentials no longer decrypt" path. Callers on the OAuth-grant path
    # must be able to record what actually went wrong instead.
    test "records the cause-specific message when :cause is given" do
      integration = insert(:calendar_integration, provider: "google")

      assert :ok =
               ReauthHandling.flag(:calendar, integration, :expired_grant)

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth == true
      refute reloaded.sync_error =~ "decrypted"
      assert reloaded.sync_error =~ "expired or been revoked"
      assert reloaded.sync_error =~ "reconnect the integration"
    end

    # A flag can be raised from a process carrying anyone's locale: a LiveView
    # acting for whoever clicked, not the owner. The reason is therefore stored
    # as its English source and translated only when a viewer renders it.
    test "stores the reason in English whatever locale flags it, and translates it per viewer" do
      integration = insert(:calendar_integration, provider: "google")
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)

      assert :ok =
               ReauthHandling.flag(:calendar, integration, :expired_grant)

      reloaded = Repo.reload!(integration)

      assert reloaded.sync_error ==
               "Access to the connected account has expired or been revoked. Please reconnect the integration."

      assert ConnectionLabels.reconnect_reason(reloaded) ==
               "Der Zugriff auf das verbundene Konto ist abgelaufen oder wurde widerrufen. Bitte verbinden Sie die Integration erneut."
    end

    # One sentence per operation rather than an interpolated action: only a
    # whole msgid can be looked up again when the dashboard renders it.
    test "Zoom's missing-scope reasons are msgids the dashboard can translate" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)

      for operation <- [:write, :update, :delete] do
        message = Scopes.reauth_message(operation)
        assert message =~ ~r/^Zoom is missing the permission/

        translated = ConnectionLabels.reconnect_reason(%{needs_reauth: true, sync_error: message})
        assert translated =~ ~r/^Zoom fehlt die für das .+ erforderliche Berechtigung/
      end
    end

    test "flags a video integration through the video queries" do
      integration = insert(:video_integration, provider: "zoom")

      assert :ok = ReauthHandling.flag(:video, integration, :rejected_credentials)

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth == true
      assert reloaded.sync_error =~ "rejected the stored credentials"
    end
  end

  @factories %{calendar: :calendar_integration, video: :video_integration}

  describe "flag_and_notify/3" do
    # Each flagger decides from the struct it loaded, and two that loaded the
    # row before either wrote both see `needs_reauth: false`. Only the row
    # knows which write was the transition. (The email job's own uniqueness
    # is no help here: it is the backstop, not the decision.)
    test "a flagger holding a stale, unflagged struct does not email again" do
      for kind <- [:calendar, :video] do
        stale = insert(@factories[kind], needs_reauth: false)

        assert {:ok, _flagged} = ReauthHandling.flag_and_notify(kind, stale, "Reconnect, please.")
        assert [first] = reauth_emails(stale)
        Repo.delete!(first)

        assert {:ok, _flagged} = ReauthHandling.flag_and_notify(kind, stale, "Reconnect, please.")
        assert reauth_emails(stale) == []
      end
    end

    # Every later flag reads the row as already flagged, so a flag that
    # committed without its email would leave the owner never told. The job
    # insert is made to fail with a check named as one Oban's changeset
    # declares, so it comes back as `{:error, changeset}` rather than raising;
    # it is gone again with the test's transaction.
    test "a flag whose email cannot be queued is rolled back, and the next flag emails" do
      integration = insert(:calendar_integration, needs_reauth: false)

      Repo.query!("""
      ALTER TABLE oban_jobs ADD CONSTRAINT priority_range
        CHECK (args->>'action' IS DISTINCT FROM 'send_integration_reauth_notification') NOT VALID
      """)

      capture_log(fn ->
        assert {:error, :notification_failed} =
                 ReauthHandling.flag_and_notify(:calendar, integration, "Reconnect, please.")
      end)

      refute Repo.reload!(integration).needs_reauth

      Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT priority_range")

      assert {:ok, _flagged} =
               ReauthHandling.flag_and_notify(:calendar, integration, "Reconnect, please.")

      assert Repo.reload!(integration).needs_reauth
      assert [_email] = reauth_emails(integration)
    end

    test "re-flagging updates the message and does not email again" do
      integration = insert(:calendar_integration, needs_reauth: true, sync_error: "Old reason.")

      assert {:ok, _flagged} =
               ReauthHandling.flag_and_notify(:calendar, integration, "New reason.")

      assert Repo.reload!(integration).sync_error == "New reason."
      assert reauth_emails(integration) == []
    end
  end

  defp reauth_emails(integration) do
    [worker: Tymeslot.Workers.EmailWorker]
    |> all_enqueued()
    |> Enum.filter(
      &(&1.args["action"] == "send_integration_reauth_notification" and
          &1.args["integration_id"] == integration.id)
    )
  end
end
