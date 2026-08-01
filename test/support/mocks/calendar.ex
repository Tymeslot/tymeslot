defmodule Tymeslot.Mocks.Calendar do
  @moduledoc """
  Calendar provider mocks (CalendarMock + Google/Outlook OAuth helpers) and
  the `event/1` fixture builder used to construct synthetic calendar events.

  See `Tymeslot.TestMocks` for the public API (`setup_calendar_mocks/1`,
  `mock_calendar_event/1`).
  """

  import Mox

  @spec setup(keyword()) :: term()
  def setup(opts \\ []) do
    events = Keyword.get(opts, :events, [])
    result = Keyword.get(opts, :result, {:ok, events})

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> result end)
    |> stub(:get_booking_integration_info, fn _user_id ->
      {:error, :no_integration}
    end)
    |> stub(:create_event, fn _event_data, _context -> {:ok, %{uid: "mock-created-uid"}} end)
    |> stub(:update_event, fn _uid, _event_data, _context -> :ok end)

    google_url =
      Keyword.get(opts, :google_oauth_url, "https://accounts.google.com/o/oauth2/v2/auth?test=1")

    outlook_url =
      Keyword.get(
        opts,
        :outlook_oauth_url,
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?test=1"
      )

    stub(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id, _redirect_uri ->
      google_url
    end)

    stub(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _user_id, _redirect_uri ->
      outlook_url
    end)
  end

  @doc """
  Stubs just the calendar read paths to return no events — the common
  "user has no conflicting calendar events" setup, without the extra
  create/update/oauth stubs that `setup/1` installs.
  """
  @spec stub_no_events() :: term()
  def stub_no_events do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id,
                                                                _start_date,
                                                                _end_date ->
      {:ok, []}
    end)
  end

  @spec event(keyword()) :: map()
  def event(opts \\ []) do
    %{
      summary: Keyword.get(opts, :summary, "Test Meeting"),
      start_time: Keyword.get(opts, :start_time, DateTime.utc_now()),
      end_time: Keyword.get(opts, :end_time, DateTime.add(DateTime.utc_now(), 30, :minute)),
      uid: Keyword.get(opts, :uid, "test-uid-#{System.unique_integer([:positive])}")
    }
  end
end
