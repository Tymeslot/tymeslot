defmodule Tymeslot.BookingSeries.ErasureTest do
  @moduledoc """
  A booking series holds its booker's name and email beside its sessions,
  so erasing the invitee, by request or by the retention purge, clears it
  with them.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.InviteeData
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.MeetingSchema

  @email "ada@example.com"
  @window_days 730

  defp ended(days_ago) do
    end_time = DateTime.utc_now() |> DateTime.add(-days_ago, :day) |> DateTime.truncate(:second)
    [start_time: DateTime.add(end_time, -30, :minute), end_time: end_time]
  end

  defp series_with_sessions(host, ages_in_days, attrs \\ []) do
    series =
      insert(
        :booking_series,
        Keyword.merge(
          [organizer_user: host, attendee_email: @email, occurrences_count: length(ages_in_days)],
          attrs
        )
      )

    sessions =
      ages_in_days
      |> Enum.with_index(1)
      |> Enum.map(fn {days_ago, position} ->
        insert(
          :meeting,
          ended(days_ago) ++
            [
              status: :completed,
              organizer_user_id: host.id,
              attendee_name: series.attendee_name,
              attendee_email: series.attendee_email,
              series_id: series.id,
              series_position: position
            ]
        )
      end)

    {series, sessions}
  end

  defp series_payment(host, series),
    do:
      insert(:paid_booking_payment,
        host_user_id: host.id,
        series_id: series.id,
        attendee_email: @email,
        attendee_name: "Ada"
      )

  describe "erasure by request" do
    test "erasing the invitee erases the series" do
      host = insert(:user)
      {series, [first, second]} = series_with_sessions(host, [20, 13])
      {other, _sessions} = series_with_sessions(host, [20, 13], attendee_email: "bob@example.com")

      assert {:ok, %{series: 1, meetings: 2}} = InviteeData.erase(" ADA@example.com ")

      erased = Repo.get!(SeriesSchema, series.id)
      assert erased.attendee_name == ""
      assert erased.attendee_email == "erased-#{series.id}@erased.invalid"
      assert %DateTime{} = erased.invitee_data_erased_at

      for session <- [first, second] do
        assert %{attendee_name: nil, attendee_email: nil} = Repo.get!(MeetingSchema, session.id)
      end

      untouched = Repo.get!(SeriesSchema, other.id)
      assert untouched.attendee_email == "bob@example.com"
      assert untouched.invitee_data_erased_at == nil
    end

    test "erasing the invitee clears the series payment at once, sessions still in the window" do
      host = insert(:user)
      {series, _sessions} = series_with_sessions(host, [20, 13])
      payment = series_payment(host, series)

      assert {:ok, %{booking_payments: 1}} = InviteeData.erase(@email)

      assert %{attendee_email: nil, attendee_name: nil} =
               Repo.get!(BookingPaymentSchema, payment.id)
    end

    test "an erasure for one host leaves another host's series alone" do
      host = insert(:user)
      other_host = insert(:user)
      {mine, _sessions} = series_with_sessions(host, [27, 20])
      {theirs, _sessions} = series_with_sessions(other_host, [27, 20])

      assert {:ok, %{series: 1}} = InviteeData.erase_for_host(host.id, @email)

      assert %{attendee_name: ""} = Repo.get!(SeriesSchema, mine.id)
      assert %{attendee_email: @email} = Repo.get!(SeriesSchema, theirs.id)
    end
  end

  describe "the retention purge" do
    test "the retention purge erases a finished series" do
      host = insert(:user)
      {finished, _sessions} = series_with_sessions(host, [@window_days + 20, @window_days + 13])

      InviteeData.anonymise_expired(@window_days)

      erased = Repo.get!(SeriesSchema, finished.id)
      assert erased.attendee_name == ""
      assert erased.attendee_email == "erased-#{finished.id}@erased.invalid"
      assert %DateTime{} = erased.invitee_data_erased_at
    end

    test "a series with a session inside the window keeps its booker until that one ages out" do
      host = insert(:user)
      {series, [_old, recent]} = series_with_sessions(host, [@window_days + 20, 10])

      InviteeData.anonymise_expired(@window_days)

      kept = Repo.get!(SeriesSchema, series.id)
      assert kept.attendee_email == @email
      assert kept.invitee_data_erased_at == nil

      recent
      |> Changeset.change(ended(@window_days + 1))
      |> Repo.update!()

      InviteeData.anonymise_expired(@window_days)

      assert %{attendee_name: "", invitee_data_erased_at: %DateTime{}} =
               Repo.get!(SeriesSchema, series.id)
    end

    test "a series payment keeps its booker until the series' last session ages out" do
      host = insert(:user)
      {series, [_old, recent]} = series_with_sessions(host, [@window_days + 20, 10])
      payment = series_payment(host, series)

      InviteeData.anonymise_expired(@window_days)

      assert %{attendee_email: @email, attendee_name: "Ada"} =
               Repo.get!(BookingPaymentSchema, payment.id)

      recent |> Changeset.change(ended(@window_days + 1)) |> Repo.update!()
      InviteeData.anonymise_expired(@window_days)

      assert %{attendee_email: nil, attendee_name: nil} =
               Repo.get!(BookingPaymentSchema, payment.id)
    end

    test "a group series is erased once every seat's session has aged out" do
      host = insert(:user)

      series =
        insert(:booking_series,
          organizer_user: host,
          attendee_email: @email,
          occurrences_count: 2
        )

      [old_meeting, recent_meeting] =
        for days_ago <- [@window_days + 20, 10] do
          insert(:meeting, ended(days_ago) ++ [status: :completed, organizer_user_id: host.id])
        end

      for {meeting, position} <- [{old_meeting, 1}, {recent_meeting, 2}] do
        insert(:participant,
          meeting: meeting,
          email: @email,
          series_id: series.id,
          series_position: position
        )
      end

      InviteeData.anonymise_expired(@window_days)
      assert %{invitee_data_erased_at: nil} = Repo.get!(SeriesSchema, series.id)

      recent_meeting |> Changeset.change(ended(@window_days + 1)) |> Repo.update!()
      InviteeData.anonymise_expired(@window_days)

      assert %{attendee_name: "", invitee_data_erased_at: %DateTime{}} =
               Repo.get!(SeriesSchema, series.id)
    end
  end
end
