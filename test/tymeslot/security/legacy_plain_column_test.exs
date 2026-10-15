defmodule Tymeslot.Security.LegacyPlainColumnTest do
  @moduledoc """
  The plain predecessors of encrypted secrets are kept for an image rollback,
  and the previous release reads them. A plain copy must therefore be emptied
  whenever its value changes, or the rollback would bring back a value the
  user replaced or removed; a row that never changes keeps its copy.

  Each test seeds the plain column as the migration's backfill left it, then
  drives the real write path.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :security
  @moduletag :integration

  alias Tymeslot.FreeBusy
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Webhooks

  describe "free/busy token" do
    setup do
      {:ok, profile} = FreeBusy.enable_feed(insert(:profile))
      seed_plain("profiles", profile.id, "freebusy_token", profile.freebusy_token)
      %{profile: profile}
    end

    test "regenerating it empties the plain copy", %{profile: profile} do
      {:ok, _profile} = FreeBusy.regenerate_token(profile)
      assert plain("profiles", profile.id, "freebusy_token") == nil
    end

    test "disabling the feed empties the plain copy", %{profile: profile} do
      {:ok, _profile} = FreeBusy.disable_feed(profile)
      assert plain("profiles", profile.id, "freebusy_token") == nil
    end
  end

  describe "webhook URL" do
    setup do
      webhook = insert(:webhook, url: "https://example.com/old")
      seed_plain("webhooks", webhook.id, "url", "https://example.com/old")
      %{webhook: webhook}
    end

    test "editing it empties the plain copy", %{webhook: webhook} do
      {:ok, updated} = Webhooks.update_webhook(webhook, %{url: "https://example.com/new"})

      assert updated.url == "https://example.com/new"
      assert plain("webhooks", webhook.id, "url") == nil
    end

    test "an edit that leaves the URL alone keeps the plain copy", %{webhook: webhook} do
      {:ok, _updated} =
        Webhooks.update_webhook(webhook, %{name: "Renamed", url: "https://example.com/old"})

      assert plain("webhooks", webhook.id, "url") == "https://example.com/old"
    end
  end

  describe "custom meeting link" do
    setup do
      integration =
        insert(:video_integration, provider: "custom", custom_meeting_url: "https://zoom.us/j/1")

      seed_plain(
        "video_integrations",
        integration.id,
        "custom_meeting_url",
        "https://zoom.us/j/1"
      )

      %{integration: integration}
    end

    test "editing it empties the plain copy", %{integration: integration} do
      {:ok, _updated} =
        VideoIntegrationQueries.update(integration, %{custom_meeting_url: "https://zoom.us/j/2"})

      assert plain("video_integrations", integration.id, "custom_meeting_url") == nil
    end

    test "an edit that leaves the link alone keeps the plain copy", %{integration: integration} do
      {:ok, _updated} = VideoIntegrationQueries.update(integration, %{name: "Renamed"})

      assert plain("video_integrations", integration.id, "custom_meeting_url") ==
               "https://zoom.us/j/1"
    end
  end

  describe "push notification secrets" do
    setup do
      integration =
        insert(:calendar_integration,
          google_channel_secret: "old-channel-secret",
          graph_client_state: "old-client-state"
        )

      seed_plain(
        "calendar_integrations",
        integration.id,
        "google_channel_secret",
        "old-channel-secret"
      )

      seed_plain(
        "calendar_integrations",
        integration.id,
        "graph_client_state",
        "old-client-state"
      )

      %{integration: integration}
    end

    test "a renewed Google channel empties the old secret's plain copy only",
         %{integration: integration} do
      {:ok, _updated} =
        CalendarIntegrationWebhookQueries.update_push_channel(integration, %{
          google_channel_secret: "new-channel-secret"
        })

      assert plain("calendar_integrations", integration.id, "google_channel_secret") == nil

      assert plain("calendar_integrations", integration.id, "graph_client_state") ==
               "old-client-state"
    end

    test "a new Graph subscription empties the old client state's plain copy",
         %{integration: integration} do
      {:ok, _updated} =
        CalendarIntegrationWebhookQueries.update_graph_subscription(integration, %{
          graph_client_state: "new-client-state"
        })

      assert plain("calendar_integrations", integration.id, "graph_client_state") == nil
    end

    test "sync bookkeeping that leaves the secrets alone keeps both plain copies",
         %{integration: integration} do
      {:ok, _updated} =
        CalendarIntegrationQueries.update_sync_state(integration, %{google_sync_token: "next"})

      assert plain("calendar_integrations", integration.id, "google_channel_secret") ==
               "old-channel-secret"

      assert plain("calendar_integrations", integration.id, "graph_client_state") ==
               "old-client-state"
    end
  end

  defp seed_plain(table, id, column, value) do
    Repo.query!("UPDATE #{table} SET #{column} = $1 WHERE id = $2", [value, id])
  end

  defp plain(table, id, column) do
    %{rows: [[value]]} = Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [id])
    value
  end
end
