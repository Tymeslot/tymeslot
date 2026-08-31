defmodule Tymeslot.Workers.VideoIntegrationDisconnectWorkerCircuitBreakerTest do
  @moduledoc """
  Drives the disconnect worker against a genuinely open circuit breaker and a
  full drain page. Both trip global, VM-wide state (the video circuit
  breakers, and — for the pagination cases — the drain page size read from
  application env), so this module runs `async: false`, mirroring
  `calendar_api_circuit_breaker_test.exs`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers

  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoIntegrationDisconnectWorker
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  setup do
    VideoCircuitBreaker.reset(:zoom)
    on_exit(fn -> VideoCircuitBreaker.reset(:zoom) end)
  end

  describe "when the provider's circuit breaker is open" do
    test "snoozes instead of purging while attempts remain" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      insert_meeting_for_user(user, %{
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "circuit-open-1"
      })

      {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)
      trip_zoom_breaker()

      assert {:snooze, _seconds} =
               perform_job(
                 VideoIntegrationDisconnectWorker,
                 %{"integration_id" => integration.id},
                 attempt: 1
               )

      # Credentials must survive: the breaker will recover on its own, and the
      # row is still needed to authenticate once it does.
      assert {:ok, _still_there} = VideoIntegrationQueries.get(integration.id)
    end

    test "purges on the last attempt rather than snoozing forever" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting_a =
        insert_meeting_for_user(user, %{
          start_offset: 86_400,
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: "circuit-open-a"
        })

      meeting_b =
        insert_meeting_for_user(user, %{
          start_offset: 172_800,
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: "circuit-open-b"
        })

      {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)
      trip_zoom_breaker()

      # A permanently open breaker must not leave the row (and its OAuth
      # credentials) stranded forever: the worker's own last-attempt safety
      # valve has to fire even though every result in the batch is
      # `:circuit_open`, not a plain failure.
      assert :ok =
               perform_job(
                 VideoIntegrationDisconnectWorker,
                 %{"integration_id" => integration.id},
                 attempt: 5
               )

      assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
      # The rooms themselves are left behind on the provider (the breaker
      # refused every call), so the join links are not silently cleared.
      assert Repo.reload!(meeting_a).video_room_id == "circuit-open-a"
      assert Repo.reload!(meeting_b).video_room_id == "circuit-open-b"
    end
  end

  describe "draining more meetings than one page covers" do
    setup do
      Application.put_env(:tymeslot, :video_disconnect_drain_page_limit, 1)

      on_exit(fn ->
        Application.delete_env(:tymeslot, :video_disconnect_drain_page_limit)
      end)
    end

    test "retries instead of purging once a page fills up" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      insert_meeting_for_user(user, %{
        start_offset: 86_400,
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "page-1"
      })

      insert_meeting_for_user(user, %{
        start_offset: 172_800,
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "page-2"
      })

      {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      # Only one of the two rooms is drained (the injected page limit is 1),
      # so the job must retry rather than purge with the second room left
      # behind, silently orphaned.
      assert {:error, :more_rooms_to_drain} =
               perform_job(
                 VideoIntegrationDisconnectWorker,
                 %{"integration_id" => integration.id}
               )

      assert {:ok, _still_there} = VideoIntegrationQueries.get(integration.id)
    end

    test "purges once the retry finds the next page empty" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      insert_meeting_for_user(user, %{
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "page-1"
      })

      {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      # A single meeting exactly filling a page of 1 cannot be told apart from
      # "there might be one more" without an extra round trip, so the worker
      # conservatively retries rather than risk purging with a room left
      # behind. The room itself is drained on this pass either way.
      assert {:error, :more_rooms_to_drain} =
               perform_job(
                 VideoIntegrationDisconnectWorker,
                 %{"integration_id" => integration.id}
               )

      assert {:ok, _still_there} = VideoIntegrationQueries.get(integration.id)

      # The retry's page comes back empty (the only meeting was already
      # drained above), so this pass purges.
      assert :ok =
               perform_job(
                 VideoIntegrationDisconnectWorker,
                 %{"integration_id" => integration.id},
                 attempt: 2
               )

      assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
    end
  end

  defp trip_zoom_breaker do
    # `failure_threshold` for zoom (via `VideoCircuitBreaker`'s
    # `@default_config`, since zoom has no per-provider override) is 3.
    # `{:provider_error, _}` is the tag `BreakerOutcome.classify/1` treats as
    # unconditional evidence of an outage; a bare `{:error, atom}` with an
    # unrecognised reason classifies as `:ignore` and would not trip it.
    Enum.each(1..3, fn _i ->
      VideoCircuitBreaker.call(:zoom, fn -> {:provider_error, :simulated_outage} end)
    end)

    assert %{status: :open} = VideoCircuitBreaker.status(:zoom)
  end

  defp insert_zoom_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Zoom",
      provider: "zoom",
      base_url: nil,
      api_key_encrypted: nil,
      tenant_id_encrypted: nil,
      client_id_encrypted: nil,
      client_secret_encrypted: nil,
      teams_user_id_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting meeting:delete:meeting",
      provider_account_id: nil
    )
  end
end
