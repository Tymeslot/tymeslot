defmodule Tymeslot.Bookings.ZoomReconnectTest do
  @moduledoc """
  A booking moved while its Zoom integration needs reconnecting cannot reach
  the Zoom meeting, and its sync job is discarded. Reconnecting through Zoom's
  consent screen proves the new grant, so it sends the meeting its current time
  again, whichever way the callback finds the integration.
  """

  # Not async: the Zoom circuit breaker is application-wide, so this module
  # needs the breaker reset that only runs between non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :video
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.ZoomOAuthHelperMock

  @account_id "zoom-account-1"
  @room_id "123456789"
  @full_scope "meeting:write:meeting meeting:update:meeting meeting:delete:meeting"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  for {path, targeted?} <- [
        {"the reconnect button", true},
        {"connecting the account again", false}
      ] do
    test "a reschedule made while Zoom needed reconnecting reaches the meeting after #{path}" do
      %{user: user} = create_always_bookable_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: @room_id,
          summary: "Customer call"
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 3)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:ok, rescheduled} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      # The grant predates the scope a reschedule needs, so the sync is refused
      # without calling Zoom, discarded, and the integration flagged.
      assert %{discard: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)
      assert Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth
      refute_enqueued(worker: VideoSyncWorker)

      # The owner consents again at Zoom.
      assert {:ok, %{needs_reauth: false}} =
               Video.match_or_create_oauth_integration(
                 user.id,
                 "zoom",
                 "Zoom",
                 @account_id,
                 if(unquote(targeted?), do: integration.id),
                 %{
                   access_token: "fresh-access-token",
                   refresh_token: "fresh-refresh-token",
                   token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
                   oauth_scope: @full_scope,
                   is_active: true,
                   provider_account_id: @account_id
                 }
               )

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => meeting.id, "action" => "update"}
      )

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, url, body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/" <> @room_id
        assert {"Authorization", "Bearer fresh-access-token"} in headers
        assert Jason.decode!(body)["start_time"] == DateTime.to_iso8601(rescheduled.start_time)
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert %{success: 1, failure: 0, discard: 0} = Oban.drain_queue(queue: :video_rooms)
    end
  end

  test "reconnecting an integration that was not flagged sends the meeting nothing" do
    %{user: user} = create_always_bookable_profile()
    integration = insert_zoom_integration(user, oauth_scope: @full_scope)

    insert_meeting_for_user(user, %{
      video_integration_id: integration.id,
      video_provider: "zoom",
      video_room_id: @room_id
    })

    assert {:ok, _integration} =
             Video.match_or_create_oauth_integration(
               user.id,
               "zoom",
               "Zoom",
               @account_id,
               integration.id,
               %{access_token: "fresh-access-token", oauth_scope: @full_scope}
             )

    refute_enqueued(worker: VideoSyncWorker)
  end

  defp insert_zoom_integration(user, overrides \\ []) do
    insert(
      :video_integration,
      Keyword.merge(
        [
          user: user,
          name: "Zoom",
          provider: "zoom",
          base_url: nil,
          api_key_encrypted: nil,
          tenant_id_encrypted: nil,
          client_id_encrypted: nil,
          client_secret_encrypted: nil,
          teams_user_id_encrypted: nil,
          access_token_encrypted: Encryption.encrypt("old-access-token"),
          refresh_token_encrypted: Encryption.encrypt("old-refresh-token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting meeting:delete:meeting",
          provider_account_id: @account_id
        ],
        overrides
      )
    )
  end
end
