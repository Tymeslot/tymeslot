defmodule Tymeslot.TestMocks do
  @moduledoc """
  Centralized mock setup for tests to reduce duplication and improve maintainability.
  """

  import Mox

  @doc """
  Sets up MiroTalk API mocks with default successful responses.
  """
  @spec setup_mirotalk_mocks(keyword()) :: term()
  def setup_mirotalk_mocks(opts \\ []) do
    room_url = Keyword.get(opts, :room_url, "https://test.mirotalk.com/join/test-room-123")
    _room_id = Keyword.get(opts, :room_id, "test-room-123")
    create_result = Keyword.get(opts, :create_result, {:ok, room_url})

    Tymeslot.MiroTalkAPIMock
    |> stub(:create_meeting_room, fn -> create_result end)
    |> stub(:extract_room_id, fn url ->
      case String.contains?(url, "/join/") do
        true -> url |> String.split("/join/") |> List.last()
        false -> nil
      end
    end)
    |> stub(:create_direct_join_url, fn room_id, participant_name ->
      "#{room_url}?name=#{URI.encode(participant_name)}&room_id=#{room_id}"
    end)
    |> stub(:create_secure_direct_join_url, fn _room_id, name, role, _datetime ->
      case role do
        "organizer" -> "#{room_url}?role=organizer&token=org123"
        "attendee" -> "#{room_url}?role=attendee&token=att456"
        _ -> "#{room_url}?name=#{URI.encode(name)}&role=#{role}"
      end
    end)
  end

  @doc """
  Sets up Calendar mocks with configurable responses.
  """
  @spec setup_calendar_mocks(keyword()) :: term()
  def setup_calendar_mocks(opts \\ []) do
    events = Keyword.get(opts, :events, [])
    result = Keyword.get(opts, :result, {:ok, events})

    Tymeslot.CalendarMock
    |> stub(:list_events_in_range, fn _start_time, _end_time -> result end)
    |> stub(:get_events_for_range_fresh, fn _start_date, _end_date -> result end)

    # Setup OAuth helper mocks
    google_url = Keyword.get(opts, :google_oauth_url, "https://accounts.google.com/o/oauth2/v2/auth?test=1")
    outlook_url = Keyword.get(opts, :outlook_oauth_url, "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?test=1")

    stub(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id, _redirect_uri -> google_url end)

    stub(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _user_id, _redirect_uri -> outlook_url end)
  end

  @doc """
  Sets up Email Service mocks.
  """
  @spec setup_email_mocks(keyword()) :: term()
  def setup_email_mocks(opts \\ []) do
    send_result = Keyword.get(opts, :send_result, :ok)

    Tymeslot.EmailServiceMock
    |> stub(:send_appointment_confirmation_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_appointment_confirmation_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_appointment_confirmations, fn _details -> {send_result, send_result} end)
    |> stub(:send_appointment_reminder_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_appointment_reminder_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_appointment_reminders, fn _details -> {send_result, send_result} end)
    |> stub(:send_appointment_reminders, fn _details, _time -> {send_result, send_result} end)
    |> stub(:send_appointment_cancellation, fn _email, _details -> send_result end)
    |> stub(:send_cancellation_emails, fn _details -> {send_result, send_result} end)
    |> stub(:send_calendar_sync_error, fn _meeting, _error -> send_result end)
    |> stub(:send_email_verification, fn _user, _url -> send_result end)
    |> stub(:send_password_reset, fn _user, _url -> send_result end)
    |> stub(:send_email_change_verification, fn _user, _email, _url -> send_result end)
    |> stub(:send_email_change_notification, fn _user, _email -> send_result end)
    |> stub(:send_email_change_confirmations, fn _user, _old, _new -> {send_result, send_result} end)
    |> stub(:send_contact_form, fn _name, _email, _subject, _msg -> send_result end)
    |> stub(:send_reschedule_request, fn _meeting -> send_result end)
  end

  @doc """
  Sets up all standard mocks for a typical successful flow.
  """
  @spec setup_standard_mocks() :: term()
  def setup_standard_mocks do
    setup_mirotalk_mocks()
    setup_calendar_mocks()
    setup_email_mocks()
  end

  @doc """
  Sets up mocks for error scenarios.
  """
  @spec setup_error_mocks(atom()) :: term()
  def setup_error_mocks(error_type) do
    case error_type do
      :mirotalk_failure ->
        setup_mirotalk_mocks(create_result: {:error, "MiroTalk API error"})
        setup_calendar_mocks()
        setup_email_mocks()

      :calendar_failure ->
        setup_mirotalk_mocks()
        setup_calendar_mocks(result: {:error, "Calendar connection failed"})
        setup_email_mocks()

      :email_failure ->
        setup_mirotalk_mocks()
        setup_calendar_mocks()
        setup_email_mocks(send_result: {:error, "Email delivery failed"})
    end
  end

  @doc """
  Creates a mock event for calendar testing.
  """
  @spec mock_calendar_event(keyword()) :: map()
  def mock_calendar_event(opts \\ []) do
    %{
      summary: Keyword.get(opts, :summary, "Test Meeting"),
      start_time: Keyword.get(opts, :start_time, DateTime.utc_now()),
      end_time: Keyword.get(opts, :end_time, DateTime.add(DateTime.utc_now(), 30, :minute)),
      uid: Keyword.get(opts, :uid, "test-uid-#{System.unique_integer([:positive])}")
    }
  end
end
