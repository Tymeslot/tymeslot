defmodule Tymeslot.Integrations.Shared.ReauthHandlingTest do
  @moduledoc """
  Verifies the shared reauth-flagging policy: logging, calling the supplied
  `mark_needs_reauth` function, and mapping its result.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :security

  import ExUnit.CaptureLog

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRow

  describe "flag/2" do
    test "logs a warning, persists the flag, and returns :ok" do
      integration = insert(:calendar_integration, provider: "caldav")

      log =
        capture_log(fn ->
          assert :ok =
                   ReauthHandling.flag(integration,
                     mark_needs_reauth: &CalendarIntegrationQueries.mark_needs_reauth/2,
                     log_prefix: "Calendar"
                   )
        end)

      assert log =~ "credentials cannot be decrypted"

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth == true
      assert reloaded.sync_error =~ "could not be decrypted"
    end

    test "returns {:error, changeset} and logs an error when persistence fails" do
      integration = insert(:calendar_integration, provider: "caldav")

      failing_mark = fn _integration, _message ->
        changeset = Changeset.add_error(Changeset.change(integration), :base, "nope")
        {:error, %{changeset | action: :update}}
      end

      log =
        capture_log(fn ->
          assert {:error, %Changeset{}} =
                   ReauthHandling.flag(integration,
                     mark_needs_reauth: failing_mark,
                     log_prefix: "Calendar"
                   )
        end)

      assert log =~ "Failed to persist needs_reauth flag"
    end

    # The decryption message above is the default because `flag/2` was built for
    # the "credentials no longer decrypt" path. Callers on the OAuth-grant path
    # must be able to record what actually went wrong instead.
    test "records the cause-specific message when :cause is given" do
      integration = insert(:calendar_integration, provider: "google")

      assert :ok =
               ReauthHandling.flag(integration,
                 mark_needs_reauth: &CalendarIntegrationQueries.mark_needs_reauth/2,
                 cause: :expired_grant
               )

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
               ReauthHandling.flag(integration,
                 mark_needs_reauth: &CalendarIntegrationQueries.mark_needs_reauth/2,
                 cause: :expired_grant
               )

      reloaded = Repo.reload!(integration)

      assert reloaded.sync_error ==
               "Access to the connected account has expired or been revoked. Please reconnect the integration."

      assert ConnectionRow.reconnect_reason(reloaded) ==
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

        translated = ConnectionRow.reconnect_reason(%{needs_reauth: true, sync_error: message})
        assert translated =~ ~r/^Zoom fehlt die für das .+ erforderliche Berechtigung/
      end
    end

    test "uses the default provider_label when no override is given" do
      integration = insert(:calendar_integration, provider: "google")

      assert :ok =
               ReauthHandling.flag(integration,
                 mark_needs_reauth: &CalendarIntegrationQueries.mark_needs_reauth/2
               )

      assert Repo.reload!(integration).needs_reauth == true
    end
  end
end
