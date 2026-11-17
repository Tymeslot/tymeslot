defmodule Tymeslot.Emails.SeriesBuilder do
  @moduledoc """
  Builds the payload the series emails render: the series, its booker and
  host, and each of its sessions as `Tymeslot.Emails.AppointmentBuilder`
  builds a single booking's.

  A session is a meeting on a one-to-one type and a seat (its meeting
  preloaded) on a group type. A seat's payload is the meeting as its
  participant sees it (`Tymeslot.Meetings.Recipient`), so its reschedule and
  cancel links are the seat's own and its calendar identity is the seat's.

  Each session also carries its `:position` in the series, the series'
  `:series_count`, a `:dashboard_url` for the organiser and `:video_pending`:
  the session's video room is wanted but has no join link yet, so the email
  promises the link in the reminder instead.
  """

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.JoinUrl
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Profiles

  @type occurrence :: MeetingSchema.t() | ParticipantSchema.t()

  @type t :: %{
          required(:series) => SeriesSchema.t(),
          required(:sessions) => [map()],
          required(:count) => pos_integer(),
          required(:attendee_name) => String.t(),
          required(:attendee_email) => String.t(),
          required(:organizer_name) => String.t(),
          required(:organizer_email) => String.t(),
          required(:meeting_type) => String.t() | nil,
          required(:series_url) => String.t() | nil,
          required(:total) => %{cents: non_neg_integer(), currency: String.t()} | nil,
          optional(atom()) => term()
        }

  @doc """
  The payload for `series` and the sessions an email is about, in series
  order (at least one).

  Options: `:currency`, the currency the series was paid in. With it and
  the series' `unit_price_cents`, the payload carries the `:total` paid for
  these sessions; without either, `:total` is nil and no amount is shown.
  `:cancelled`, the ids of those of `occurrences` already cancelled, marks
  them `cancelled: true`: listed in their place, without links or a
  calendar entry.
  """
  @spec build(SeriesSchema.t(), [occurrence(), ...], keyword()) :: t()
  def build(%SeriesSchema{} = series, [_first | _rest] = occurrences, opts \\ []) do
    cancelled = Keyword.get(opts, :cancelled, [])

    sessions =
      occurrences
      |> Enum.sort_by(& &1.series_position)
      |> Enum.map(&Map.put(session(&1, series), :cancelled, &1.id in cancelled))

    first = hd(sessions)
    count = length(sessions)

    first
    |> Map.take([
      :meeting_type,
      :duration,
      :organizer_name,
      :organizer_email,
      :organizer_title,
      :organizer_avatar_url,
      :organizer_locale,
      :organizer_time_format,
      :organizer_user_id,
      :attendee_locale,
      :attendee_timezone,
      :start_time_attendee_tz,
      :start_time_owner_tz
    ])
    |> Map.merge(%{
      series: series,
      sessions: sessions,
      count: count,
      attendee_name: series.attendee_name,
      attendee_email: series.attendee_email,
      attendee_locale: RecipientLocale.attendee_locale(first),
      series_url: MeetingLinks.series_url(series, organizer_profile(series)),
      total: total(series.unit_price_cents, Keyword.get(opts, :currency), count)
    })
  end

  @doc """
  The organiser's copy of `details`, a `build/3` payload: every session,
  and the series' meeting type, in the organiser's own wording rather than
  the attendee's copies the payload is built with
  (`AppointmentBuilder.with_original_texts/1`), as the organiser's copy of
  a single booking's email is.
  """
  @spec organizer_copy(t()) :: t()
  def organizer_copy(%{sessions: [_first | _rest] = sessions} = details) do
    [first | _rest] = sessions = Enum.map(sessions, &AppointmentBuilder.with_original_texts/1)
    %{details | sessions: sessions, meeting_type: first.meeting_type}
  end

  defp session(%MeetingSchema{} = meeting, series) do
    meeting
    |> AppointmentBuilder.from_meeting()
    |> annotate(meeting, meeting.series_position, series)
  end

  defp session(%ParticipantSchema{meeting: %MeetingSchema{} = meeting} = seat, series) do
    meeting
    |> AppointmentBuilder.from_meeting(Recipient.from_participant(seat), nil)
    |> annotate(meeting, seat.series_position, series)
  end

  defp annotate(details, meeting, position, series) do
    Map.merge(details, %{
      position: position,
      series_count: series.occurrences_count,
      dashboard_url: MeetingLinks.host_view_url(meeting.id),
      video_pending: video_pending?(meeting, details)
    })
  end

  # The session has a video integration but no join link yet: its room is
  # still being made, or will not be.
  defp video_pending?(%MeetingSchema{video_integration_id: nil}, _details), do: false
  defp video_pending?(_meeting, details), do: is_nil(JoinUrl.for(:attendee, details))

  defp organizer_profile(%SeriesSchema{organizer_user_id: user_id}) do
    case Profiles.get_profile_by_user_id(user_id) do
      {:ok, profile} -> profile
      {:error, :not_found} -> nil
    end
  end

  defp total(unit_price_cents, currency, count)
       when is_integer(unit_price_cents) and is_binary(currency),
       do: %{cents: unit_price_cents * count, currency: currency}

  defp total(_unit_price_cents, _currency, _count), do: nil
end
