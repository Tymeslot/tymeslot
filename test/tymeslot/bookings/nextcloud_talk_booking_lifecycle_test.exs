defmodule Tymeslot.Bookings.NextcloudTalkBookingLifecycleTest do
  @moduledoc """
  A booking on a Nextcloud Talk integration from end to end.

  A Talk conversation is an object on the organiser's server with a lifecycle
  of its own, so every step here runs through the entry point that drives it in
  production: the booking submission and the room job it queues, a reschedule,
  a cancellation and the daily clean-up. The jobs they queue are drained from
  the queue, not built by hand. Only the HTTP client is stubbed: it plays the
  Nextcloud server and records every request it receives, so each step asserts
  exactly what Nextcloud was sent, and then what the booking holds.
  """

  # Not async: the room job calls the provider from a supervised task, which
  # needs the global Mox mode, and the Talk circuit breakers are VM-wide.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :video
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.ExpiredVideoRoomCleanupWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.VideoSyncWorker

  @room_path "/ocs/v2.php/apps/spreed/api/v4/room"
  @room_list @room_path <> "?noStatusUpdate=1&includeLastMessage=0"
  @login "organiser"
  @app_password "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
  @new_app_password "Zyxwv-Utsrq-Ponml-Kjihg-Fedcb"
  @timezone "Europe/Berlin"
  @token "abc123xy"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()
    with_config(:tymeslot, :video_room_retention_days, 7)

    # Any request no step expects still reaches the test, so it shows up in the
    # recorded requests instead of vanishing into the default stub.
    test = self()

    stub(HTTPClientMock, :request, fn method, url, body, headers, _opts ->
      send(test, {:nextcloud, method, url, decode(body), headers})
      {:error, %Mint.TransportError{reason: :econnrefused}}
    end)

    %{user: user} = create_always_bookable_profile()
    %{user: user}
  end

  test "creates the conversation for a booking, moves it with a reschedule and deletes it on cancellation",
       %{user: user} do
    server = server("lifecycle")
    integration = insert_talk_integration(user, server)
    meeting_type = insert_meeting_type(user, integration, "Talk consultation")
    start_time = booking_start(3)

    assert {:ok, %MeetingSchema{} = booked} =
             Orchestrator.submit_booking(booking_params(user, meeting_type, start_time),
               organizer_user_id: user.id
             )

    assert DateTime.compare(booked.start_time, start_time) == :eq
    assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => booked.id})

    # The booking: no earlier attempt left a conversation, so one call creates
    # a public conversation named after it, with a lobby that lifts at the
    # meeting's start and the booking's reference in its description.
    nextcloud_answers([{200, ocs([])}, {201, ocs(%{"token" => @token})}])
    assert %{success: 1, failure: 0} = drain_video_rooms()

    assert requests() == [
             {:get, server <> @room_list, nil},
             {:post, server <> @room_path,
              %{
                "roomType" => 3,
                "roomName" => "Talk consultation with Ada Lovelace",
                "permissions" => 244,
                "lobbyState" => 1,
                "lobbyTimer" => DateTime.to_unix(start_time),
                "description" => "Booked through Tymeslot.\n\nReference: " <> reference(booked)
              }}
           ]

    join_link = server <> "/index.php/call/" <> @token
    with_room = Repo.reload!(booked)

    assert %{
             video_room_id: @token,
             video_provider: "nextcloud_talk",
             video_room_enabled: true,
             meeting_url: ^join_link,
             organizer_video_url: ^join_link,
             attendee_video_url: ^join_link
           } = with_room

    # The confirmation was held back for the room, and goes out now it exists.
    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_confirmation_emails", "meeting_id" => booked.id}
    )

    # A reschedule changes nothing on the server by itself: the link is the
    # same for every time, so nothing is rebuilt inline.
    new_start = DateTime.add(start_time, 2, :day)

    assert {:ok, _rescheduled} =
             Reschedule.execute(booked.uid, reschedule_params(new_start), %{}, user.id)

    assert requests() == []
    assert_enqueued(worker: VideoSyncWorker, args: sync_args(booked, "update"))

    # The sync moves the lobby first, then renames with the name the
    # conversation was created with.
    nextcloud_answers([{200, ocs(%{})}, {200, ocs([])}])
    assert %{success: 1, failure: 0} = drain_video_rooms()

    assert requests() == [
             {:put, server <> @room_path <> "/" <> @token <> "/webinar/lobby",
              %{"state" => 1, "timer" => DateTime.to_unix(new_start)}},
             {:put, server <> @room_path <> "/" <> @token,
              %{"roomName" => "Talk consultation with Ada Lovelace"}}
           ]

    rescheduled = Repo.reload!(booked)
    assert DateTime.compare(rescheduled.start_time, new_start) == :eq

    assert %{video_room_id: @token, meeting_url: ^join_link, attendee_video_url: ^join_link} =
             rescheduled

    # Cancelling deletes the conversation and forgets the room, join links and
    # all: the conversation they point at no longer exists.
    assert {:ok, _cancelled} = Cancel.execute(booked.uid)
    assert requests() == []
    assert_enqueued(worker: VideoSyncWorker, args: sync_args(booked, "delete"))

    nextcloud_answers([{200, ocs(nil)}])
    assert %{success: 1, failure: 0} = drain_video_rooms()

    assert requests() == [{:delete, server <> @room_path <> "/" <> @token, nil}]

    assert %{
             status: "cancelled",
             video_room_id: nil,
             video_room_enabled: false,
             organizer_video_url: nil,
             attendee_video_url: nil
           } = Repo.reload!(booked)
  end

  test "a room job that stopped waiting before Nextcloud answered adopts that conversation on its retry",
       %{user: user} do
    server = server("late-answer")
    integration = insert_talk_integration(user, server)
    booked = book(user, integration, booking_start(3))

    # Nextcloud creates the conversation, but its answer never arrives in time.
    made = create_without_answer(server)

    # The retry finds that conversation by the booking's reference and records
    # it, rather than creating a second one nothing would ever delete.
    nextcloud_answers([{200, ocs([%{"token" => "other123", "description" => ""}, made])}])
    assert %{success: 1, failure: 0} = drain_video_rooms(with_scheduled: true)

    assert requests() == [{:get, server <> @room_list, nil}]

    join_link = server <> "/index.php/call/" <> @token

    assert %{video_room_id: @token, meeting_url: ^join_link, attendee_video_url: ^join_link} =
             Repo.reload!(booked)
  end

  test "a conversation adopted after a reschedule moves its lobby to the booking's new start",
       %{user: user} do
    server = server("late-answer-moved")
    integration = insert_talk_integration(user, server)
    booked = book(user, integration, booking_start(3))
    made = create_without_answer(server)

    # The guest moves the booking while it has no recorded room: nothing on
    # Nextcloud can be moved yet.
    new_start = DateTime.add(booked.start_time, 1, :day)

    assert {:ok, _rescheduled} =
             Reschedule.execute(booked.uid, reschedule_params(new_start), %{}, user.id)

    refute_enqueued(worker: VideoSyncWorker)
    assert requests() == []

    # The retry adopts the conversation, still waiting for the old start, and
    # moves its lobby. Its name already matches the booking.
    nextcloud_answers([{200, ocs([made])}, {200, ocs(%{})}])
    assert %{success: 1, failure: 0} = drain_video_rooms(with_scheduled: true)

    assert requests() == [
             {:get, server <> @room_list, nil},
             {:put, server <> @room_path <> "/" <> @token <> "/webinar/lobby",
              %{"state" => 1, "timer" => DateTime.to_unix(new_start)}}
           ]

    assert Repo.reload!(booked).video_room_id == @token
  end

  # Each answer leaves the conversation settled from Tymeslot's side: deleted
  # now, already deleted by hand, or kept by its owner, which only the owner can
  # change in Nextcloud.
  for {outcome, status, body} <- [
        {"deletes it", 200, {:ocs, nil}},
        {"no longer has it", 404, :empty},
        {"keeps it for its owner", 403, {:ocs, %{"error" => "preserved"}}}
      ] do
    test "the daily clean-up settles a conversation a week after its meeting when Nextcloud #{outcome}",
         %{user: user} do
      server = server("cleanup-#{unquote(status)}")
      integration = insert_talk_integration(user, server)
      meeting = book_with_conversation(user, integration, server)

      # A booking that took place: it ended eight days ago.
      held = move_into_past(meeting, 8)

      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})
      assert_enqueued(worker: VideoSyncWorker, args: sync_args(held, "delete"))

      nextcloud_answers([{unquote(status), answer_body(unquote(Macro.escape(body)))}])
      assert %{success: 1, failure: 0, discard: 0} = drain_video_rooms()

      assert requests() == [{:delete, server <> @room_path <> "/" <> @token, nil}]
      assert %{video_room_id: nil, video_room_enabled: false} = Repo.reload!(held)

      # The next night finds nothing left to delete and sends Nextcloud nothing.
      assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})
      assert %{success: 0, failure: 0} = drain_video_rooms()
      assert requests() == []
    end
  end

  test "the daily clean-up leaves the conversation of a meeting that ended within the week",
       %{user: user} do
    server = server("recent")
    integration = insert_talk_integration(user, server)
    meeting = book_with_conversation(user, integration, server)
    held = move_into_past(meeting, 6)

    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})

    refute_enqueued(worker: VideoSyncWorker)
    assert requests() == []
    assert Repo.reload!(held).video_room_id == @token
  end

  test "a reschedule while Nextcloud throttles Tymeslot waits and then moves the conversation",
       %{user: user} do
    server = server("throttled")
    integration = insert_talk_integration(user, server)
    meeting = book_with_conversation(user, integration, server)
    new_start = DateTime.add(meeting.start_time, 1, :day)

    assert {:ok, _rescheduled} =
             Reschedule.execute(meeting.uid, reschedule_params(new_start), %{}, user.id)

    lobby_url = server <> @room_path <> "/" <> @token <> "/webinar/lobby"
    lobby = %{"state" => 1, "timer" => DateTime.to_unix(new_start)}

    # Throttled: the job snoozes rather than failing or retrying at once.
    nextcloud_answers([{429, ""}])
    assert %{snoozed: 1, failure: 0} = drain_video_rooms()
    assert requests() == [{:put, lobby_url, lobby}]

    assert [%Oban.Job{state: "scheduled", meta: %{"snoozed" => 1}} = job] =
             all_enqueued(worker: VideoSyncWorker)

    assert DateTime.after?(job.scheduled_at, DateTime.utc_now())

    # Once the throttle lifts, the same job moves the lobby and renames.
    nextcloud_answers([{200, ocs(%{})}, {200, ocs([])}])
    assert %{success: 1, failure: 0} = drain_video_rooms(with_scheduled: true)

    assert requests() == [
             {:put, lobby_url, lobby},
             {:put, server <> @room_path <> "/" <> @token,
              %{"roomName" => "Talk consultation with Ada Lovelace"}}
           ]
  end

  test "a reschedule the account may no longer apply is dropped without renaming",
       %{user: user} do
    server = server("forbidden")
    integration = insert_talk_integration(user, server)
    meeting = book_with_conversation(user, integration, server)
    new_start = DateTime.add(meeting.start_time, 1, :day)

    assert {:ok, _rescheduled} =
             Reschedule.execute(meeting.uid, reschedule_params(new_start), %{}, user.id)

    # A 403 repeats on every attempt, so the job is discarded, not retried.
    nextcloud_answers([{403, ocs(%{"error" => "permissions"})}])
    assert %{discard: 1, failure: 0, success: 0} = drain_video_rooms()

    assert requests() == [
             {:put, server <> @room_path <> "/" <> @token <> "/webinar/lobby",
              %{"state" => 1, "timer" => DateTime.to_unix(new_start)}}
           ]

    assert Repo.reload!(meeting).video_room_id == @token
    refute Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth
  end

  test "a refused app password stops every later request until the integration is reconnected, which deletes a cancelled booking's conversation",
       %{user: user} do
    server = server("refused")
    integration = insert_talk_integration(user, server)
    meeting = book_with_conversation(user, integration, server)
    new_start = DateTime.add(meeting.start_time, 1, :day)

    assert {:ok, _rescheduled} =
             Reschedule.execute(meeting.uid, reschedule_params(new_start), %{}, user.id)

    # Nextcloud refuses the app password: the job is discarded, since a retry
    # would count against the server's brute-force protection, and the
    # integration is flagged for reconnection.
    nextcloud_answers([{401, ""}])
    assert %{discard: 1, failure: 0} = drain_video_rooms()

    assert [{:put, _lobby_url, _lobby}] = requests()
    assert Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth

    # Cancelling sends the refused credentials nowhere, and keeps the room so
    # it can still be deleted once the integration is reconnected.
    assert {:ok, _cancelled} = Cancel.execute(meeting.uid)
    assert %{discard: 1, failure: 0} = drain_video_rooms()

    assert requests() == []
    assert %{status: "cancelled", video_room_id: @token} = Repo.reload!(meeting)

    # Reconnecting with a new app password deletes the conversation the
    # cancellation could not.
    nextcloud_answers([{200, signed_in()}, {200, talk_capabilities()}])

    assert {:ok, %{needs_reauth: false}} =
             Video.update_integration(user.id, integration.id, %{
               name: "Nextcloud Talk",
               base_url: server,
               client_id: @login,
               client_secret: @new_app_password
             })

    assert [{:get, _user_url, nil}, {:get, _capabilities_url, nil}] =
             requests(@new_app_password)

    assert_enqueued(worker: VideoSyncWorker, args: sync_args(meeting, "delete"))

    nextcloud_answers([{200, ocs(nil)}])
    assert %{success: 1, failure: 0, discard: 0} = drain_video_rooms()

    assert requests(@new_app_password) == [{:delete, server <> @room_path <> "/" <> @token, nil}]
    assert %{video_room_id: nil, video_room_enabled: false} = Repo.reload!(meeting)
  end

  test "a reschedule made while the app password was refused reaches the conversation once the organiser reconnects",
       %{user: user} do
    server = server("reconnected")
    integration = insert_talk_integration(user, server)
    meeting = book_with_conversation(user, integration, server)
    new_start = DateTime.add(meeting.start_time, -1, :day)

    # The app password is revoked: the first request refused flags the
    # integration.
    assert {:ok, _rescheduled} =
             Reschedule.execute(meeting.uid, reschedule_params(new_start), %{}, user.id)

    nextcloud_answers([{401, ""}])
    assert %{discard: 1, failure: 0} = drain_video_rooms()
    assert [{:put, _lobby_url, _lobby}] = requests()
    assert Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth

    # A guest moves the booking again while the integration waits to be
    # reconnected. Nextcloud is not asked, and nothing is left to retry.
    newer_start = DateTime.add(new_start, 2, :hour)

    assert {:ok, _rescheduled} =
             Reschedule.execute(meeting.uid, reschedule_params(newer_start), %{}, user.id)

    assert %{discard: 1, failure: 0} = drain_video_rooms()
    assert requests() == []
    refute_enqueued(worker: VideoSyncWorker)

    # The organiser enters a new app password in the edit dialog, which is
    # proven against the server before it is saved.
    nextcloud_answers([{200, signed_in()}, {200, talk_capabilities()}])

    assert {:ok, %{needs_reauth: false}} =
             Video.update_integration(user.id, integration.id, %{
               name: "Nextcloud Talk",
               base_url: server,
               client_id: @login,
               client_secret: @new_app_password
             })

    assert [{:get, user_url, nil}, {:get, capabilities_url, nil}] = requests(@new_app_password)
    assert user_url == server <> "/ocs/v2.php/cloud/user"
    assert capabilities_url == server <> "/ocs/v2.php/cloud/capabilities"
    assert_enqueued(worker: VideoSyncWorker, args: sync_args(meeting, "update"))

    # The queued update moves the lobby to the booking's current start and
    # renames the conversation, signed in with the new app password.
    nextcloud_answers([{200, ocs(%{})}, {200, ocs([])}])
    assert %{success: 1, failure: 0, discard: 0} = drain_video_rooms()

    assert requests(@new_app_password) == [
             {:put, server <> @room_path <> "/" <> @token <> "/webinar/lobby",
              %{"state" => 1, "timer" => DateTime.to_unix(newer_start)}},
             {:put, server <> @room_path <> "/" <> @token,
              %{"roomName" => "Talk consultation with Ada Lovelace"}}
           ]
  end

  # ----- the Nextcloud server -----

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

  # An answer is a status and body, or a request that never completed.
  defp respond({:error, _exception} = failure), do: failure
  defp respond({status, body}), do: {:ok, %Req.Response{status: status, body: body}}

  # The reference a booking's conversation carries: the first 16 hex
  # characters of the SHA-256 of its meeting id.
  defp reference(meeting) do
    :sha256 |> :crypto.hash(meeting.id) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # The requests Nextcloud received since the last call, in order. Each must
  # have signed in with the integration's login name and `app_password`.
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

  # What Nextcloud answers the account endpoint with, which a connection test
  # asks before it trusts anything the capabilities say.
  defp signed_in, do: ocs(%{"id" => @login})

  defp talk_capabilities do
    ocs(%{
      "capabilities" => %{
        "spreed" => %{"version" => "25.0.0", "features" => ["conversation-creation-all"]}
      }
    })
  end

  defp answer_body({:ocs, data}), do: ocs(data)
  defp answer_body(:empty), do: ""

  # ----- bookings -----

  defp drain_video_rooms(opts \\ []),
    do: Oban.drain_queue(Keyword.merge([queue: :video_rooms], opts))

  defp sync_args(meeting, action), do: %{"meeting_id" => meeting.id, "action" => action}

  defp book(user, integration, start_time) do
    meeting_type = insert_meeting_type(user, integration, "Talk consultation")

    assert {:ok, %MeetingSchema{} = booked} =
             Orchestrator.submit_booking(booking_params(user, meeting_type, start_time),
               organizer_user_id: user.id
             )

    booked
  end

  # The room job's first attempt: Nextcloud creates the conversation, but the
  # answer never arrives, so the job fails and nothing is recorded. Returns the
  # conversation as Nextcloud would now list it to its owner.
  defp create_without_answer(server) do
    nextcloud_answers([{200, ocs([])}, {:error, %Req.TransportError{reason: :timeout}}])
    assert %{success: 0} = drain_video_rooms()

    assert [{:get, list_url, nil}, {:post, create_url, created}] = requests()
    assert {list_url, create_url} == {server <> @room_list, server <> @room_path}

    %{
      "token" => @token,
      "type" => created["roomType"],
      "participantType" => 1,
      "name" => created["roomName"],
      "defaultPermissions" => created["permissions"],
      "lobbyState" => created["lobbyState"],
      "lobbyTimer" => created["lobbyTimer"],
      "description" => created["description"]
    }
  end

  # A booking whose room job has already created its conversation.
  defp book_with_conversation(user, integration, server) do
    meeting_type = insert_meeting_type(user, integration, "Talk consultation")
    start_time = booking_start(3)

    {:ok, meeting} =
      Orchestrator.submit_booking(booking_params(user, meeting_type, start_time),
        organizer_user_id: user.id
      )

    nextcloud_answers([{200, ocs([])}, {201, ocs(%{"token" => @token})}])
    assert %{success: 1} = drain_video_rooms()
    assert [{:get, _list_url, nil}, {:post, url, _params}] = requests()
    assert url == server <> @room_path

    Repo.reload!(meeting)
  end

  # Time passing: the meeting keeps its length and ends `days` ago.
  defp move_into_past(meeting, days) do
    length_seconds = DateTime.diff(meeting.end_time, meeting.start_time)
    end_time = DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

    meeting
    |> Changeset.change(
      start_time: DateTime.add(end_time, -length_seconds, :second),
      end_time: end_time
    )
    |> Repo.update!()
  end

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

  defp reschedule_params(start_time) do
    local = DateTime.shift_zone!(start_time, @timezone)

    %{
      date: Date.to_iso8601(DateTime.to_date(local)),
      time: Calendar.strftime(local, "%H:%M"),
      duration: "30min",
      user_timezone: @timezone
    }
  end

  # A whole hour `days` from now, so the open schedule always offers it.
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

  # Each test gets its own server, so no test's calls reach another test's
  # per-host circuit breaker.
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
