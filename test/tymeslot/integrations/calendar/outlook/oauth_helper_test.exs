defmodule Tymeslot.Integrations.Calendar.Outlook.OAuthHelperTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  import Tymeslot.Factory
  import Mox

  setup :verify_on_exit!

  setup do
    Application.put_env(:tymeslot, :outlook_oauth,
      client_id: "outlook-id",
      client_secret: "outlook-secret",
      state_secret: "outlook-state"
    )

    :ok
  end

  describe "authorization_url/2 and /3" do
    test "generates valid Outlook OAuth URL" do
      url = OAuthHelper.authorization_url(1, "http://uri")
      assert url =~ "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
      assert url =~ "client_id=outlook-id"
      assert url =~ "scope=https%3A%2F%2Fgraph.microsoft.com%2FCalendars.ReadWrite"
    end

    test "accepts options for login_hint" do
      url = OAuthHelper.authorization_url(1, "http://uri", login_hint: "user@example.com")
      assert url =~ "login_hint=user%40example.com"
    end
  end

  describe "handle_callback/3" do
    test "creates new integration and performs discovery" do
      user = insert(:user)
      insert(:profile, user: user)
      state = %{user_id: user.id, integration_id: nil}

      expect_token_response("at-123", "rt-123")

      # Mock Outlook API for discovery
      expect(OutlookCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{"id" => "cal1", "name" => "Calendar", "isDefaultCalendar" => true}]}
      end)

      assert {:ok, integration} = OAuthHelper.handle_callback("code", "http://uri", state)
      assert integration.user_id == user.id
      assert integration.provider == "outlook"

      # The initial delta baseline is seeded by the worker, not inline: the
      # integration lands with a nil `graph_delta_link` and the enqueued job
      # bootstraps it (and registers the Graph subscription) on its first run.
      assert is_nil(integration.graph_delta_link)

      assert_enqueued(
        worker: RefreshOutlookCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )

      integration =
        CalendarIntegrationSchema.decrypt_credentials(integration)

      assert integration.access_token == "at-123"
    end

    test "handles 3-tuple error from discovery without crashing" do
      user = insert(:user)
      insert(:profile, user: user)
      state = %{user_id: user.id, integration_id: nil}

      expect_token_response("at-ok", "rt-ok")

      # Discovery returns a 3-tuple error (as real providers do on 401/403)
      expect(OutlookCalendarAPIMock, :list_calendars, fn _client ->
        {:error, :unauthorized, "Token expired or invalid"}
      end)

      # Should still succeed — discovery failure is non-fatal
      assert {:ok, integration} = OAuthHelper.handle_callback("code", "http://uri", state)
      assert integration.provider == "outlook"
    end
  end

  # The token exchange is the only HTTP call `handle_callback/3` makes — calendar
  # discovery goes through `OutlookCalendarAPIMock`, and the initial delta fetch
  # is the enqueued worker's job, not the callback's.
  # A sync that kept failing pauses the integration, and a paused calendar
  # gives up its place as the primary. Reconnecting reactivates it, and a user
  # with no other calendar has to get it back as the primary too.
  describe "handle_callback/3 reconnecting a paused integration" do
    test "makes it the primary again when the user has none" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      paused =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          provider_account_id: "outlook-oid-paused",
          is_active: false,
          calendar_list: [%{"id" => "cal1", "name" => "Calendar", "selected" => true}]
        )

      state = %{user_id: user.id, integration_id: paused.id}
      expect_token_response("at-new", "rt-new", id_token("outlook-oid-paused"))

      assert {:ok, reconnected} = OAuthHelper.handle_callback("code", "http://uri", state)
      assert {reconnected.id, reconnected.is_active} == {paused.id, true}

      assert Repo.reload!(profile).primary_calendar_integration_id == paused.id
    end
  end

  defp expect_token_response(access_token, refresh_token, id_token \\ nil) do
    tokens = %{
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "expires_in" => 3600,
      "scope" => "Calendars.ReadWrite"
    }

    body = if id_token, do: Map.put(tokens, "id_token", id_token), else: tokens

    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      {:ok, %{status: 200, body: Jason.encode!(body)}}
    end)
  end

  defp id_token(oid) do
    payload =
      Base.url_encode64(Jason.encode!(%{"oid" => oid, "email" => "a@example.com"}),
        padding: false
      )

    "#{Base.url_encode64("{}", padding: false)}.#{payload}.#{Base.url_encode64("sig", padding: false)}"
  end

  describe "token operations" do
    test "exchange_code_for_tokens falls back to the calendar scope when the response omits it" do
      # Microsoft may answer without `refresh_token` or `scope`. The requested
      # calendar scope is then the recorded one, otherwise the integration would
      # be stored as having no permissions at all.
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "access_token" => "at",
               "expires_in" => 3600
             })
         }}
      end)

      assert {:ok, tokens} = OAuthHelper.exchange_code_for_tokens("code", "uri")
      assert tokens.access_token == "at"
      assert is_nil(tokens.refresh_token)
      assert tokens.scope =~ "https://graph.microsoft.com/Calendars.ReadWrite"
    end
  end
end
