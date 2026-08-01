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
