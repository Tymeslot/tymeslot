defmodule Tymeslot.SlackTest do
  use Tymeslot.DataCase, async: false

  @moduletag :slack
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Notifications.Events
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Slack
  alias Tymeslot.Slack.{SlackIntegrationSchema, SlackQueries}

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      slack_notifications_allowed: true,
      http_client_module: Tymeslot.HTTPClientMock,
      environment: :test
    )

    :ok
  end

  describe "CRUD" do
    test "create_integration/2 inserts an OAuth-mode integration" do
      user = insert(:user)

      assert {:ok, integration} =
               Slack.create_integration(user.id, %{
                 name: "Acme Slack",
                 app_mode: "oauth",
                 bot_token: "xoxb-real",
                 team_id: "T1",
                 channel_id: "C1",
                 events: ["meeting.created"]
               })

      assert integration.name == "Acme Slack"
      assert integration.channel_id == "C1"
    end

    test "create_integration/2 returns :feature_disabled when Slack is off" do
      user = insert(:user)
      setup_config(:tymeslot, slack_notifications_allowed: false)

      assert {:error, :feature_disabled} =
               Slack.create_integration(user.id, %{name: "x"})
    end

    test "list_integrations/1 returns the user's integrations" do
      user = insert(:user)
      insert(:slack_integration, user: user)
      assert [_one] = Slack.list_integrations(user.id)
    end

    test "delete_integration/1 removes the record" do
      integration = insert(:slack_integration)
      assert {:ok, _deleted} = Slack.delete_integration(integration)
      assert {:error, :not_found} = Slack.get_integration(integration.id, integration.user_id)
    end
  end

  describe "reenable_integration/1" do
    test "re-enables an auto-disabled integration, clearing disabled fields" do
      integration =
        insert(:slack_integration,
          is_active: false,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Too many consecutive failures: channel_not_found",
          failure_count: 10
        )

      assert {:ok, reenabled} = Slack.reenable_integration(integration)
      assert reenabled.is_active == true
      assert is_nil(reenabled.disabled_at)
      assert is_nil(reenabled.disabled_reason)
    end

    test "returns {:error, :insufficient_plan} when Features.check_access denies access" do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.SlackTest.DenyAccessChecker
      )

      integration =
        insert(:slack_integration,
          is_active: false,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "failures"
        )

      assert {:error, :insufficient_plan} = Slack.reenable_integration(integration)

      # Integration must remain unchanged
      assert {:ok, unchanged} = Slack.get_integration(integration.id, integration.user_id)
      assert unchanged.is_active == false
      refute is_nil(unchanged.disabled_at)
    end
  end

  describe "toggle_integration/1" do
    test "toggles active to paused" do
      integration = insert(:slack_integration, is_active: true)
      assert {:ok, toggled} = Slack.toggle_integration(integration)
      refute toggled.is_active
    end

    test "rejects pending_oauth integrations" do
      integration = insert(:slack_integration, app_mode: "oauth", channel_id: nil)
      assert {:error, :invalid_state} = Slack.toggle_integration(integration)
    end
  end

  describe "complete_oauth/2" do
    test "persists a pending stub with the supplied bot token" do
      user = insert(:user)

      assert {:ok, stub} =
               Slack.complete_oauth(user.id, %{
                 name: "Acme",
                 bot_token: "xoxb-new",
                 team_id: "T1",
                 team_name: "Acme",
                 authed_user_id: "U7",
                 scope: "chat:write",
                 events: ["meeting.created"]
               })

      assert SlackIntegrationSchema.status(stub) == :pending_oauth
      assert SlackIntegrationSchema.bot_token(stub) == "xoxb-new"
    end

    test "returns :feature_disabled when Slack is off" do
      user = insert(:user)
      setup_config(:tymeslot, slack_notifications_allowed: false)

      assert {:error, :feature_disabled} =
               Slack.complete_oauth(user.id, %{name: "x", bot_token: "t", team_id: "T"})
    end

    test "removes stale pending OAuth stubs for the same user before inserting" do
      user = insert(:user)

      insert(:slack_integration,
        user: user,
        app_mode: "oauth",
        channel_id: nil,
        bot_token_encrypted: Encryption.encrypt("xoxb-old-1"),
        name: "Stale 1"
      )

      insert(:slack_integration,
        user: user,
        app_mode: "oauth",
        channel_id: nil,
        bot_token_encrypted: Encryption.encrypt("xoxb-old-2"),
        name: "Stale 2"
      )

      assert {:ok, latest} =
               Slack.complete_oauth(user.id, %{
                 name: "Latest",
                 bot_token: "xoxb-new",
                 team_id: "T1",
                 events: ["meeting.created"]
               })

      remaining = Slack.list_integrations(user.id)

      assert Enum.map(remaining, & &1.id) == [latest.id]
      assert SlackIntegrationSchema.bot_token(latest) == "xoxb-new"
    end
  end

  describe "set_channel/2" do
    test "transitions a pending stub to active" do
      user = insert(:user)

      {:ok, stub} =
        Slack.complete_oauth(user.id, %{
          name: "Acme",
          bot_token: "xoxb-new",
          team_id: "T1",
          events: ["meeting.created"]
        })

      assert {:ok, active} =
               Slack.set_channel(stub, %{channel_id: "C42", channel_name: "#booking"})

      assert SlackIntegrationSchema.status(active) == :active
      assert active.channel_id == "C42"
    end
  end

  describe "list_channels/1" do
    test "paginates conversations.list across cursors" do
      integration = insert(:slack_integration)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        body =
          Jason.encode!(%{
            "ok" => true,
            "channels" => [
              %{"id" => "C1", "name" => "general", "is_private" => false}
            ],
            "response_metadata" => %{"next_cursor" => "page2"}
          })

        {:ok, %{status: 200, body: body}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
        assert params["cursor"] == "page2"

        body =
          Jason.encode!(%{
            "ok" => true,
            "channels" => [
              %{"id" => "C2", "name" => "private-team", "is_private" => true}
            ],
            "response_metadata" => %{"next_cursor" => ""}
          })

        {:ok, %{status: 200, body: body}}
      end)

      assert {:ok, channels} = Slack.list_channels(integration)

      assert channels == [
               %{id: "C1", name: "general", is_private: false},
               %{id: "C2", name: "private-team", is_private: true}
             ]
    end

    test "returns transport error from underlying API" do
      integration = insert(:slack_integration)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert {:error, {:transport_error, _reason}} = Slack.list_channels(integration)
    end
  end

  describe "test_integration/1" do
    test "sends a Block Kit message via the bot token (oauth mode)" do
      integration = insert(:slack_integration, app_mode: "oauth", channel_id: "C9")

      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        assert url == "https://slack.com/api/chat.postMessage"
        {:ok, %{status: 200, body: ~s({"ok":true})}}
      end)

      assert :ok = Slack.test_integration(integration)
    end

    test "posts to the webhook URL for webhook_url mode" do
      integration =
        insert(:slack_integration,
          app_mode: "webhook_url",
          channel_id: nil,
          bot_token_encrypted: nil,
          webhook_url_encrypted: Encryption.encrypt("https://hooks.slack.com/services/T/B/abc"),
          webhook_channel_hint: "#general"
        )

      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        assert url == "https://hooks.slack.com/services/T/B/abc"
        {:ok, %{status: 200, body: "ok"}}
      end)

      assert :ok = Slack.test_integration(integration)
    end
  end

  # `trigger_integrations_for_event/3` enqueues SlackWorker jobs. End-to-end
  # coverage of the enqueue path lives in `slack/dispatcher_test.exs` (Task 2.6)
  # and the worker test (Task 2.5) — keeping the context test focused on inputs
  # the context owns directly.

  describe "available_events/0 and slack_enabled?/0" do
    test "available_events/0 lists three meeting events" do
      events = Slack.available_events()
      assert length(events) == 3
      assert Enum.all?(events, &Map.has_key?(&1, :value))
    end

    test "slack_enabled?/0 reflects config" do
      setup_config(:tymeslot, slack_notifications_allowed: true)
      assert Slack.slack_enabled?()

      setup_config(:tymeslot, slack_notifications_allowed: false)
      refute Slack.slack_enabled?()
    end

    test "oauth_mode_available?/0 is false when neither slack_oauth_available nor client_id is set" do
      setup_config(:tymeslot,
        slack_notifications_allowed: true,
        slack_oauth_available: false,
        slack_client_id: nil
      )

      refute Slack.oauth_mode_available?()
    end

    test "oauth_mode_available?/0 is false when only slack_client_id is set" do
      setup_config(:tymeslot,
        slack_notifications_allowed: true,
        slack_oauth_available: false,
        slack_client_id: "xyz"
      )

      refute Slack.oauth_mode_available?()
    end

    test "oauth_mode_available?/0 is false when only slack_oauth_available is set" do
      setup_config(:tymeslot,
        slack_notifications_allowed: true,
        slack_oauth_available: true,
        slack_client_id: nil
      )

      refute Slack.oauth_mode_available?()
    end

    test "oauth_mode_available?/0 is true when both slack_oauth_available and client_id are set" do
      setup_config(:tymeslot,
        slack_notifications_allowed: true,
        slack_oauth_available: true,
        slack_client_id: "xyz"
      )

      assert Slack.oauth_mode_available?()
    end

    test "default_events_for_new_integration/0 matches the schema's valid_events" do
      assert Slack.default_events_for_new_integration() ==
               SlackIntegrationSchema.valid_events()
    end
  end

  describe "translate_error/1" do
    test "maps channel_not_found to private-channel guidance" do
      assert Slack.translate_error({:slack_error, "channel_not_found", %{}}) =~
               "Channel not accessible"
    end

    test "maps token_revoked and account_inactive to reconnect copy" do
      assert Slack.translate_error({:error, {:slack_error, "token_revoked", %{}}}) =~
               "Reconnect"

      assert Slack.translate_error("account_inactive") =~ "Reconnect"
    end

    test "maps not_in_channel and ratelimited to specific copy" do
      assert Slack.translate_error("not_in_channel") =~ "not in this channel"
      assert Slack.translate_error("ratelimited") =~ "rate-limiting"
    end

    test "maps webhook_url_revoked to guidance to generate a new URL" do
      assert Slack.translate_error("webhook_url_revoked") =~ "Generate a new one"
    end

    test "falls back to generic Slack error message for unknown codes" do
      assert Slack.translate_error("bogus_code") == "Slack error: bogus_code"
    end

    test "maps :missing_bot_token to Slack app configuration guidance" do
      assert Slack.translate_error(:missing_bot_token) =~ "bot token app"
    end

    test "maps workspace already connected changeset to a clear message" do
      cs = %Ecto.Changeset{errors: [{:user_id, {"workspace already connected", []}}]}
      assert Slack.translate_error(cs) =~ "already connected"
    end
  end

  describe "end-to-end booking pipeline" do
    @tag :integration
    test "booking a meeting fires a Slack notification" do
      user = insert(:user)

      integration =
        insert(:slack_integration,
          user: user,
          app_mode: "oauth",
          events: ["meeting.created"],
          is_active: true
        )

      meeting = insert(:meeting, organizer_user_id: user.id)

      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        assert url == "https://slack.com/api/chat.postMessage"
        {:ok, %{status: 200, body: ~s({"ok":true,"ts":"1234.5678"})}}
      end)

      Events.meeting_created(meeting)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :slack_messages)

      assert [delivery] = SlackQueries.list_deliveries(integration.id, [])
      assert delivery.response_status == 200
      assert delivery.delivered_at

      assert {:ok, reloaded} = SlackQueries.get_integration(integration.id)
      assert reloaded.last_triggered_at
    end
  end
end

defmodule Tymeslot.SlackTest.DenyAccessChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: {:error, :insufficient_plan}
end
