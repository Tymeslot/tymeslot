defmodule Tymeslot.Bookings.NextcloudTalkRestrictedServerTest do
  @moduledoc """
  Bookings on a Nextcloud Talk integration whose server refuses to create
  conversations for a reason no retry fixes, from the booking to the moment
  the server allows them again.

  Only the HTTP client is stubbed: it plays the Nextcloud server, answering
  with the bodies a Talk 25.0.0 server sent, and records every request.
  """

  # Not async: the room job calls the provider from a supervised task, which
  # needs the global Mox mode, and the Talk circuit breakers are VM-wide.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :video
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Dashboard.VideoSettings.Components

  @login "organiser"
  @app_password "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
  @timezone "Europe/Berlin"
  @token "abc123xy"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    test = self()

    stub(HTTPClientMock, :request, fn method, url, body, headers, _opts ->
      send(test, {:nextcloud, method, url, decode(body), headers})
      {:error, %Mint.TransportError{reason: :econnrefused}}
    end)

    %{user: user} = create_always_bookable_profile()
    %{user: user}
  end

  test "a server that refuses to create conversations is explained to the organiser until it allows them",
       %{user: user} do
    server = server("restricted")
    integration = insert_talk_integration(user, server)
    meeting_type = insert_meeting_type(user, integration, "Talk consultation")

    # Two guests book while Nextcloud lets only another group create
    # conversations. Each booking is confirmed without a link: the job is
    # discarded, not retried, since the server would refuse every attempt.
    bookings =
      for days <- [3, 4] do
        assert {:ok, %MeetingSchema{} = booked} =
                 Orchestrator.submit_booking(
                   booking_params(user, meeting_type, booking_start(days)),
                   organizer_user_id: user.id
                 )

        nextcloud_answers([
          {200, ocs([])},
          {403,
           ~s({"ocs":{"meta":{"status":"failure","statuscode":403,"message":""},"data":{"error":"permissions"}}})}
        ])

        assert %{discard: 1, failure: 0, success: 0} = drain_video_rooms()
        assert [{:get, _list_url, nil}, {:post, _create_url, _params}] = requests()

        assert %{video_room_id: nil, meeting_url: nil} = Repo.reload!(booked)

        assert_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_confirmation_emails", "meeting_id" => booked.id}
        )

        booked
      end

    # The credentials work, so nothing asks for a reconnection; the refusal is
    # recorded and the owner is told once, however many bookings met it.
    assert %{needs_reauth: false, room_creation_error: :conversation_creation_restricted} =
             Repo.get!(VideoIntegrationSchema, integration.id)

    assert [%{args: email_args}] = refusal_emails()

    expect(EmailServiceMock, :send_video_room_creation_error_notification, fn owner, refused ->
      assert owner.id == user.id
      assert refused.room_creation_error == :conversation_creation_restricted
      {:ok, :sent}
    end)

    assert :ok = perform_job(EmailWorker, email_args)

    # The integration's row says what is wrong and how to fix it.
    row = integration_row(integration)
    assert row =~ "New bookings get no video link."
    assert row =~ "allow the user&#39;s group to create conversations"
    assert row =~ "No video links"

    # The Nextcloud admin allows the organiser's group, and the next booking
    # gets its conversation and link, which clears the notice.
    assert {:ok, %MeetingSchema{} = allowed} =
             Orchestrator.submit_booking(
               booking_params(user, meeting_type, booking_start(5)),
               organizer_user_id: user.id
             )

    nextcloud_answers([{200, ocs([])}, {201, ocs(%{"token" => @token})}])
    assert %{success: 1, failure: 0} = drain_video_rooms()
    assert [{:get, _list_url, nil}, {:post, _create_url, _params}] = requests()

    join_link = server <> "/index.php/call/" <> @token
    assert %{video_room_id: @token, meeting_url: ^join_link} = Repo.reload!(allowed)

    cleared = Repo.get!(VideoIntegrationSchema, integration.id)
    assert %{room_creation_error: nil, room_creation_error_since: nil} = cleared

    row = integration_row(cleared)
    refute row =~ "New bookings get no video link."
    assert row =~ "Healthy"

    # The bookings made while it refused still have no link, and nobody was
    # emailed a second time.
    assert Enum.all?(bookings, &is_nil(Repo.reload!(&1).video_room_id))
    assert length(refusal_emails()) == 1
  end

  defp refusal_emails do
    all_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_video_room_creation_error_notification"}
    )
  end

  defp integration_row(integration) do
    render_component(&Components.video_connection_row/1,
      integration: VideoIntegrationSchema.decrypt_credentials(Repo.reload!(integration)),
      myself: nil
    )
  end

  # Queues Nextcloud's answers to the next requests, in order. Every request is
  # sent back to the test, so `requests/0` shows what the server received.
  defp nextcloud_answers(answers) do
    test = self()

    Enum.each(answers, fn answer ->
      expect(HTTPClientMock, :request, fn method, url, request_body, headers, _opts ->
        send(test, {:nextcloud, method, url, decode(request_body), headers})
        respond(answer)
      end)
    end)
  end

  defp respond({:error, _exception} = failure), do: failure
  defp respond({status, body}), do: {:ok, %Req.Response{status: status, body: body}}

  defp requests(app_password \\ @app_password, acc \\ []) do
    receive do
      {:nextcloud, method, url, body, headers} ->
        assert_signed_in(headers, app_password)
        requests(app_password, [{method, url, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_signed_in(headers, app_password) do
    assert {"Authorization", "Basic " <> Base.encode64(@login <> ":" <> app_password)} in headers
    assert {"OCS-APIRequest", "true"} in headers
  end

  defp decode(""), do: nil
  defp decode(body), do: Jason.decode!(body)

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})

  defp drain_video_rooms(opts \\ []),
    do: Oban.drain_queue(Keyword.merge([queue: :video_rooms], opts))

  defp booking_params(user, meeting_type, start_time) do
    local = DateTime.shift_zone!(start_time, @timezone)

    %{
      form_data: %{
        "name" => "Ada Lovelace",
        "email" => "ada@example.com",
        "message" => "Looking forward to it"
      },
      meeting_params: %{
        date: DateTime.to_date(local),
        time: Calendar.strftime(local, "%H:%M"),
        duration: "30min",
        user_timezone: @timezone,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        with_video_room: true
      }
    }
  end

  defp booking_start(days) do
    %{
      DateTime.add(DateTime.utc_now(), days, :day)
      | hour: 13,
        minute: 0,
        second: 0,
        microsecond: {0, 0}
    }
  end

  defp insert_meeting_type(user, integration, name) do
    insert(:meeting_type,
      user: user,
      name: name,
      duration_minutes: 30,
      allow_video: true,
      video_integration_id: integration.id
    )
  end

  defp server(name), do: "https://#{name}.talk.example.com"

  defp insert_talk_integration(user, server) do
    insert(:video_integration,
      user: user,
      name: "Nextcloud Talk",
      provider: "nextcloud_talk",
      base_url: server,
      api_key_encrypted: nil,
      tenant_id_encrypted: nil,
      teams_user_id_encrypted: nil,
      access_token_encrypted: nil,
      refresh_token_encrypted: nil,
      client_id_encrypted: Encryption.encrypt(@login),
      client_secret_encrypted: Encryption.encrypt(@app_password),
      provider_account_id: server <> "||" <> @login
    )
  end
end
