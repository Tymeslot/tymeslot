defmodule Tymeslot.Security.RetiredLegacyKeyTest do
  @moduledoc """
  `LEGACY_KEY_RETIRED` set too early is an operator mistake the application
  must survive without losing a secret: every value still under the legacy key
  stays byte-for-byte in place through the sweep, the reconnection flagging and
  the background jobs that meet it, and opens again once the flag is unset.
  """

  # async: false: swaps the global keyring held in :persistent_term.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :security
  @moduletag :integration
  @moduletag :capture_log

  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.CredentialReencryption.KeyReport
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Webhooks.WebhookSchema
  alias Tymeslot.Workers.EmailWorker

  @data_key Base.encode64(:crypto.strong_rand_bytes(48))

  setup do
    original = Application.get_env(:tymeslot, Encryption)

    on_exit(fn ->
      Application.put_env(:tymeslot, Encryption, original)
      Encryption.reset_keyring()
    end)

    # Everything below is written before any data key existed: all v0.
    put_keys(data_encryption_key: nil)
    user = insert(:user)

    calendar =
      insert(:calendar_integration,
        user: user,
        username_encrypted: Encryption.encrypt("cal-user")
      )

    video =
      insert(:video_integration,
        user: user,
        provider: "custom",
        custom_meeting_url: "https://meet.example.com/standing-room"
      )

    webhook = insert(:webhook, user: user, url: "https://hooks.example.com/legacy")

    %{user: user, calendar: calendar, video: video, webhook: webhook}
  end

  test "values under the retired key survive every path that meets them, then open again",
       %{user: user, calendar: calendar, video: video, webhook: webhook} do
    stored_before = stored_ciphertexts()

    put_keys(data_encryption_key: @data_key, legacy_key_retired: true)

    assert {:ok, %{totals: %{migrated_values: 0, unrecoverable: unrecoverable}}} =
             CredentialReencryption.run()

    assert unrecoverable > 0

    perform_job(TokenRefreshJob, %{"integration_id" => calendar.id})
    HealthCheck.perform_single_check(:calendar, calendar.id)
    HealthCheck.perform_single_check(:video, video.id)
    Management.list_active_calendar_integrations(user.id)
    KeyReport.warn_about_unreadable_values()

    # The paths ran: the integrations are flagged for reconnection.
    assert Repo.get!(CalendarIntegrationSchema, calendar.id).needs_reauth
    assert Repo.get!(VideoIntegrationSchema, video.id).needs_reauth

    assert stored_ciphertexts() == stored_before

    put_keys(data_encryption_key: @data_key)

    assert Encryption.decrypt(
             Repo.get!(CalendarIntegrationSchema, calendar.id).username_encrypted
           ) ==
             "cal-user"

    assert Repo.get!(VideoIntegrationSchema, video.id).custom_meeting_url ==
             "https://meet.example.com/standing-room"

    assert Repo.get!(WebhookSchema, webhook.id).url == "https://hooks.example.com/legacy"
  end

  describe "the boot check" do
    setup do
      LogCapture.attach()
      :ok
    end

    test "names each column still holding unreadable values, with counts only", %{
      calendar: calendar
    } do
      put_keys(data_encryption_key: @data_key, legacy_key_retired: true)

      KeyReport.warn_about_unreadable_values()

      assert_receive {:captured_log,
                      %{
                        level: :error,
                        meta: %{event_type: "encryption_retired_key_values_remain"}
                      } =
                        event}

      unreadable = event.meta.unreadable_values
      assert unreadable["calendar_integrations.username_encrypted"] >= 1
      assert unreadable["webhooks.url_encrypted"] >= 1

      message = LogCapture.message_text(event.msg)
      assert message =~ "calendar_integrations.username_encrypted: "
      refute message =~ calendar.username_encrypted
      refute message =~ Base.encode64(calendar.username_encrypted)
    end

    test "gives queued email links their own advice, not the sweep" do
      %{"action" => "send_password_reset", "user_id" => 1}
      |> LinkArg.put("reset_url", "https://app.example.com/reset/queued")
      |> EmailWorker.new()
      |> Oban.insert!()

      put_keys(data_encryption_key: @data_key, legacy_key_retired: true)

      KeyReport.warn_about_unreadable_values()

      assert_receive {:captured_log,
                      %{
                        level: :error,
                        meta: %{event_type: "encryption_retired_key_values_remain"}
                      } =
                        event}

      assert event.meta.unreadable_values["oban_jobs.email_links"] == 1

      message = LogCapture.message_text(event.msg)

      assert message =~
               "Queued email links (oban_jobs.email_links: 1): unset LEGACY_KEY_RETIRED and let"

      refute message =~ "oban_jobs.email_links: 1): unset LEGACY_KEY_RETIRED, restart, run"
      assert message =~ "Stored values ("
    end

    test "stays silent when the legacy key is not retired" do
      put_keys(data_encryption_key: @data_key)

      KeyReport.warn_about_unreadable_values()

      refute_receive {:captured_log,
                      %{meta: %{event_type: "encryption_retired_key_values_remain"}}}
    end
  end

  defp put_keys(config) do
    Application.put_env(:tymeslot, Encryption, config)
    Encryption.reset_keyring()
  end

  # Every encrypted column of every swept table, raw, as stored.
  defp stored_ciphertexts do
    for {table, columns} <- CredentialReencryption.covered_tables(), into: %{} do
      rows = Repo.all(from(r in table, order_by: r.id, select: map(r, ^[:id | columns])))

      {table, rows}
    end
  end
end
