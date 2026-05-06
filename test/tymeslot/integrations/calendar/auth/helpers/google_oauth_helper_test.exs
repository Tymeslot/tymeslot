defmodule Tymeslot.Integrations.Calendar.Google.OAuthHelperTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.OAuthHelper
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Repo
  import Tymeslot.Factory
  import Mox

  setup :verify_on_exit!

  setup do
    Application.put_env(:tymeslot, :google_oauth,
      client_id: "test-id",
      client_secret: "test-secret",
      state_secret: "test-state"
    )

    :ok
  end

  describe "authorization_url/2 and /3" do
    test "returns URL from base helper" do
      url = OAuthHelper.authorization_url(1, "http://uri")
      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth"
      assert url =~ "scope=openid+email+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar"
    end

    test "handles custom scopes" do
      url = OAuthHelper.authorization_url(1, "http://uri", ["read"])
      assert url =~ "scope=openid+email+read"
    end
  end

  defp expect_token_response(access_token, refresh_token, opts \\ []) do
    id_token = Keyword.get(opts, :id_token)

    scope =
      Keyword.get(
        opts,
        :scope,
        "openid email https://www.googleapis.com/auth/calendar"
      )

    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      base = %{
        "access_token" => access_token,
        "refresh_token" => refresh_token,
        "expires_in" => 3600,
        "scope" => scope
      }

      body = if id_token, do: Map.put(base, "id_token", id_token), else: base

      {:ok, %{status: 200, body: Jason.encode!(body)}}
    end)
  end

  defp fake_id_token(sub, email \\ "test@example.com") do
    header = Base.url_encode64("{}", padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"sub" => sub, "email" => email}), padding: false)
    signature = Base.url_encode64("sig", padding: false)
    "#{header}.#{payload}.#{signature}"
  end

  describe "handle_callback/3" do
    test "creates new integration and performs discovery" do
      user = insert(:user)
      insert(:profile, user: user)
      state = GoogleOAuthHelper.generate_state(user.id)

      expect_token_response("at-123", "rt-123")

      # Mock GoogleCalendarAPIMock.list_calendars/1
      expect(GoogleCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{id: "cal1", summary: "Primary", primary: true}]}
      end)

      assert {:ok, integration} = OAuthHelper.handle_callback("code", state, "http://uri")
      assert integration.user_id == user.id
      assert integration.provider == "google"

      assert_enqueued(
        worker: Tymeslot.Workers.SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )

      integration =
        CalendarIntegrationSchema.decrypt_credentials(integration)

      assert integration.access_token == "at-123"
    end

    test "updates existing integration" do
      user = insert(:user)
      insert(:profile, user: user)
      account_id = "google-sub-123"

      existing =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: account_id,
          access_token: "old"
        )

      state = GoogleOAuthHelper.generate_state(user.id)

      expect_token_response("new-at", "new-rt", id_token: fake_id_token(account_id))

      # Expect discovery if calendar_list is empty
      expect(GoogleCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{id: "cal1", summary: "Primary", primary: true}]}
      end)

      assert {:ok, updated} = OAuthHelper.handle_callback("code", state, "http://uri")
      assert updated.id == existing.id

      # Decrypt to check virtual fields
      updated = CalendarIntegrationSchema.decrypt_credentials(updated)
      assert updated.access_token == "new-at"
    end

    test "handles 3-tuple error from discovery without crashing" do
      user = insert(:user)
      insert(:profile, user: user)
      state = GoogleOAuthHelper.generate_state(user.id)

      expect_token_response("at-ok", "rt-ok")

      # Discovery returns a 3-tuple error (as real providers do on 401/403)
      expect(GoogleCalendarAPIMock, :list_calendars, fn _client ->
        {:error, :unauthorized, "Token expired or invalid"}
      end)

      # Should still succeed — discovery failure is non-fatal
      assert {:ok, integration} = OAuthHelper.handle_callback("code", state, "http://uri")
      assert integration.provider == "google"
    end

    test "rejects callback when calendar write scope was not granted" do
      user = insert(:user)
      insert(:profile, user: user)
      state = GoogleOAuthHelper.generate_state(user.id)

      # User clicked "Continue" without ticking the Calendar checkbox —
      # Google still returns a 200 with the partial scope.
      expect_token_response("at-readonly", "rt-readonly", scope: "openid email")

      assert {:error, :calendar_scope_missing} =
               OAuthHelper.handle_callback("code", state, "http://uri")

      # No integration row should be created.
      refute Repo.exists?(
               from(i in CalendarIntegrationSchema,
                 where: i.user_id == ^user.id and i.provider == "google"
               )
             )

      # No sync job should be enqueued.
      refute_enqueued(worker: Tymeslot.Workers.SyncGoogleCalendarWorker)
    end

    test "rejects callback when only calendar.readonly was granted" do
      user = insert(:user)
      insert(:profile, user: user)
      state = GoogleOAuthHelper.generate_state(user.id)

      expect_token_response(
        "at-ro",
        "rt-ro",
        scope: "openid email https://www.googleapis.com/auth/calendar.readonly"
      )

      assert {:error, :calendar_scope_missing} =
               OAuthHelper.handle_callback("code", state, "http://uri")
    end

    test "enqueues video room retries for user's pending meetings on success" do
      user = insert(:user)
      insert(:profile, user: user)

      video_integration = insert(:video_integration, user: user)

      pending_start = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      pending_end = DateTime.add(pending_start, 60, :minute)

      pending =
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          status: "confirmed",
          video_integration_id: video_integration.id,
          video_room_id: nil,
          start_time: pending_start,
          end_time: pending_end
        )

      already_start = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)
      already_end = DateTime.add(already_start, 60, :minute)

      # A meeting that already has a video room — should NOT be re-enqueued.
      already_has_room =
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          status: "confirmed",
          video_integration_id: video_integration.id,
          video_room_id: "room-existing",
          start_time: already_start,
          end_time: already_end
        )

      state = GoogleOAuthHelper.generate_state(user.id)
      expect_token_response("at-success", "rt-success")

      expect(GoogleCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{id: "cal1", summary: "Primary", primary: true}]}
      end)

      assert {:ok, _integration} = OAuthHelper.handle_callback("code", state, "http://uri")

      assert_enqueued(
        worker: Tymeslot.Workers.VideoRoomWorker,
        args: %{"meeting_id" => pending.id, "send_emails" => false}
      )

      refute_enqueued(
        worker: Tymeslot.Workers.VideoRoomWorker,
        args: %{"meeting_id" => already_has_room.id}
      )
    end
  end

  describe "token operations" do
    test "exchange_code_for_tokens delegates to base helper" do
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

      assert {:ok, _result} = OAuthHelper.exchange_code_for_tokens("code", "uri")
    end

    test "refresh_access_token delegates to base helper" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "access_token" => "new",
               "expires_in" => 3600
             })
         }}
      end)

      assert {:ok, _result} = OAuthHelper.refresh_access_token("rt")
    end
  end
end
