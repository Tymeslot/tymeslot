defmodule TymeslotWeb.VideoOAuthCallbackPersistenceTest do
  @moduledoc """
  Connecting Google Meet, Microsoft Teams and Zoom through the real OAuth
  callback route, against the real database.

  Only the provider's token exchange is replaced (each helper's
  `exchange_code_for_tokens/3`, the HTTP boundary); the state check, the
  pending PKCE flow, the changeset, the encryption of the tokens and the
  reconnect match all run for real. The last test carries a Google Meet
  connection on into a booking and the room `VideoRoomWorker` creates with it.
  """

  # :meck replaces the helper modules globally, so nothing else may run beside it.
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :integrations
  @moduletag :video

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.OAuthFlowHelpers

  alias Phoenix.Flash
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Factory
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Integrations.Shared.OAuth.GoogleOAuthHelper
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  @secrets %{
    google: "it_google_state_secret",
    teams: "it_outlook_state_secret",
    zoom: "it_zoom_state_secret"
  }

  # Per provider: the callback route, the helper whose exchange is replaced,
  # the pending-flow provider and its state secret, and the extra fields that
  # provider's helper returns beside the tokens.
  @providers %{
    google_meet: %{
      path: "/auth/google/video/callback",
      helper: GoogleOAuthHelper,
      secret: :google,
      name: "Google Meet",
      scope: "https://www.googleapis.com/auth/meetings.space.created",
      extra: %{}
    },
    teams: %{
      path: "/auth/teams/video/callback",
      helper: TeamsOAuthHelper,
      secret: :teams,
      name: "Microsoft Teams",
      scope: "https://graph.microsoft.com/OnlineMeetings.ReadWrite offline_access",
      extra: %{tenant_id: "tenant-123", teams_user_id: "teams-user-456"}
    },
    zoom: %{
      path: "/auth/zoom/video/callback",
      helper: ZoomOAuthHelper,
      secret: :zoom,
      name: "Zoom",
      scope: "meeting:write:meeting meeting:read:meeting",
      extra: %{}
    }
  }

  setup %{conn: conn} do
    RateLimiter.clear_all()

    helpers = [GoogleOAuthHelper, TeamsOAuthHelper, ZoomOAuthHelper]

    for mod <- helpers do
      safe_unload(mod)
      :meck.new(mod, [:passthrough])
    end

    originals =
      for key <- [:google_oauth, :outlook_oauth, :zoom_oauth, :video_providers],
          into: %{},
          do: {key, Application.get_env(:tymeslot, key)}

    put_secret(:google_oauth, originals.google_oauth, @secrets.google)
    put_secret(:outlook_oauth, originals.outlook_oauth, @secrets.teams)
    put_secret(:zoom_oauth, originals.zoom_oauth, @secrets.zoom)

    Application.put_env(
      :tymeslot,
      :video_providers,
      Map.put(originals.video_providers || %{}, :zoom, enabled: true)
    )

    case Process.whereis(DashboardCache) do
      nil -> DashboardCache.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      Enum.each(helpers, &safe_unload/1)

      for {key, value} <- originals do
        if is_nil(value),
          do: Application.delete_env(:tymeslot, key),
          else: Application.put_env(:tymeslot, key, value)
      end
    end)

    user = Factory.insert(:user)
    %{user: user, conn: log_in_user(conn, user)}
  end

  for provider <- [:google_meet, :teams, :zoom] do
    describe "#{provider} callback" do
      @provider provider

      test "stores an active, encrypted integration for the account", %{conn: conn, user: user} do
        conn = callback(conn, user, @provider, "access-1", "refresh-1")

        assert redirected_to(conn) == "/dashboard/integrations?tab=video"
        assert Flash.get(conn.assigns.flash, :info) =~ "connected successfully"

        assert [row] = rows_for(user, @provider)
        assert row.provider == Atom.to_string(@provider)
        assert row.name == @providers[@provider].name
        assert row.provider_account_id == account_id(@provider)
        assert row.provider_account_email == "host@example.com"
        assert row.is_active
        refute row.needs_reauth

        # The stored columns hold ciphertext, never the token itself.
        assert byte_size(row.access_token_encrypted) > 0
        assert byte_size(row.refresh_token_encrypted) > 0
        refute row.access_token_encrypted =~ "access-1"
        refute row.refresh_token_encrypted =~ "refresh-1"

        decrypted = VideoIntegrationSchema.decrypt_credentials(row)
        assert decrypted.access_token == "access-1"
        assert decrypted.refresh_token == "refresh-1"
      end

      test "a second callback for the same account updates the row, not a new one", %{
        conn: conn,
        user: user
      } do
        callback(conn, user, @provider, "access-1", "refresh-1")
        assert [first] = rows_for(user, @provider)

        conn =
          build_conn()
          |> setup_session()
          |> log_in_user(user)
          |> callback(user, @provider, "access-2", "refresh-2")

        assert Flash.get(conn.assigns.flash, :info) =~ "connected successfully"

        assert [second] = rows_for(user, @provider)
        assert second.id == first.id
        assert second.is_active

        decrypted = VideoIntegrationSchema.decrypt_credentials(second)
        assert decrypted.access_token == "access-2"
        assert decrypted.refresh_token == "refresh-2"
      end
    end
  end

  test "teams keeps the tenant and Graph user beside the tokens, encrypted", %{
    conn: conn,
    user: user
  } do
    callback(conn, user, :teams, "access-1", "refresh-1")

    assert [row] = rows_for(user, :teams)
    refute row.tenant_id_encrypted =~ "tenant-123"

    decrypted = VideoIntegrationSchema.decrypt_credentials(row)
    assert decrypted.tenant_id == "tenant-123"
    assert decrypted.teams_user_id == "teams-user-456"
  end

  describe "a Google Meet connection carried into a booking" do
    test "the booking's room is created with the token the callback stored", %{
      conn: conn,
      user: user
    } do
      TestMocks.setup_calendar_mocks()
      profile = Factory.insert(:profile, user: user, timezone: "Europe/London")
      _schedule = open_schedule_for(profile)

      callback(conn, user, :google_meet, "meet-access-token", "meet-refresh-token")
      assert [integration] = rows_for(user, :google_meet)

      meeting_type =
        Factory.insert(:meeting_type,
          user: user,
          name: "Meet call",
          duration_minutes: 30,
          is_active: true,
          allow_video: true,
          video_integration_id: integration.id
        )

      params = %{
        form_data: %{"name" => "Attendee", "email" => "attendee@example.com"},
        meeting_params: %{
          date: Date.add(Date.utc_today(), 1),
          time: "14:00",
          duration: "30min",
          user_timezone: "Europe/London",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id,
          with_video_room: true
        }
      }

      meet_url = "https://meet.google.com/abc-defg-hij"

      expect(HTTPClientMock, :request, fn :post, url, _body, headers, _opts ->
        assert url =~ "meet.googleapis.com"
        # The worker reaches Google with the token the callback encrypted.
        assert {"Authorization", "Bearer meet-access-token"} in headers

        space = %{"name" => "spaces/CallbackSpace1", "meetingUri" => meet_url}
        {:ok, %Req.Response{status: 200, body: Jason.encode!(space)}}
      end)

      assert {:ok, meeting} = Orchestrator.submit_booking(params, organizer_user_id: user.id)
      assert meeting.video_integration_id == integration.id

      assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})

      assert %{success: 1, failure: 0} =
               Oban.drain_queue(queue: :video_rooms, with_recursion: true)

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.video_room_id == "CallbackSpace1"
      assert updated.meeting_url == meet_url
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp callback(conn, user, provider, access_token, refresh_token) do
    config = Map.fetch!(@providers, provider)

    tokens =
      Map.merge(
        %{
          access_token: access_token,
          refresh_token: refresh_token,
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second),
          scope: config.scope,
          provider_account_id: account_id(provider),
          provider_account_email: "host@example.com"
        },
        config.extra
      )

    :meck.expect(config.helper, :exchange_code_for_tokens, fn "auth-code", _uri, opts ->
      # The callback must hand over the verifier of the flow the state names.
      assert byte_size(Keyword.fetch!(opts, :code_verifier)) > 0
      {:ok, tokens}
    end)

    state = flow_state(user.id, provider, Map.fetch!(@secrets, config.secret))
    get(conn, config.path, %{"code" => "auth-code", "state" => state})
  end

  defp account_id(provider), do: "#{provider}-account-1"

  defp rows_for(user, provider) do
    Repo.all(
      from(i in VideoIntegrationSchema,
        where: i.user_id == ^user.id and i.provider == ^Atom.to_string(provider),
        order_by: i.id
      )
    )
  end

  defp put_secret(key, original, secret) do
    Application.put_env(:tymeslot, key, Keyword.merge(original || [], state_secret: secret))
  end

  defp safe_unload(mod) do
    :meck.unload(mod)
  rescue
    _error -> :ok
  end
end
