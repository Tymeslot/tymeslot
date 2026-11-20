defmodule Tymeslot.Meetings.MeetingRules do
  @moduledoc """
  The rules every full `MeetingSchema` write is held to, solo or group: the
  fields derived rather than given (`calendar_uid`, `seen_calendar_end_time`,
  `duration`), the field validations, and the database constraints the
  changeset declares.

  The schema casts and chooses the required fields, then hands the changeset
  here (`validate/2`). `MeetingSchema.status_changeset/2` deliberately bypasses
  it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset

  alias Ecto.UUID
  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.ChangesetValidators.TimeOrder
  alias Tymeslot.ChangesetValidators.TrackingParams
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.UniqueInvitation
  alias Tymeslot.Meetings.UniqueSlot

  @organizer_note_max_length 2000

  @doc """
  The longest note an organiser may leave for the guest. Anything that
  becomes one (a poll's description) is held to the same limit.
  """
  @spec organizer_note_max_length() :: pos_integer()
  def organizer_note_max_length, do: @organizer_note_max_length

  @doc """
  Derives, validates and constrains a cast meeting changeset, requiring
  `required_fields` plus the derived `calendar_uid`.
  """
  @spec validate(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate(changeset, required_fields) do
    changeset
    |> ensure_calendar_uid()
    |> ensure_seen_calendar_end()
    |> validate_required([:calendar_uid | required_fields])
    # Every writer copies `organizer_email` from the host's stored account (or
    # the operator's configured fallback), never from a form, so it is held
    # only to presence and length: an account whose address predates the
    # current format rules must still be able to take bookings.
    |> EmailChangeset.validate_email(:organizer_email, existing: true)
    |> EmailChangeset.validate_email(:attendee_email)
    |> validate_required([:attendee_locale])
    |> validate_inclusion(:attendee_locale, Locales.supported_codes(),
      message: dgettext_noop("errors", "is not a supported locale")
    )
    |> validate_number(:capacity, greater_than: 0)
    |> TimeOrder.validate_time_order(:start_time, :end_time)
    |> validate_length(:utm_source, max: 255)
    |> validate_length(:utm_medium, max: 255)
    |> validate_length(:utm_campaign, max: 255)
    |> validate_length(:utm_content, max: 255)
    |> validate_length(:utm_term, max: 255)
    |> validate_length(:referrer_host, max: 255)
    |> validate_length(:decline_reason, max: 500)
    |> validate_length(:organizer_note, max: @organizer_note_max_length)
    |> validate_length(:visitor_hash, max: 64)
    # Google Calendar's documented maximum event id length.
    |> validate_length(:provider_event_id, max: 1024)
    |> TrackingParams.validate_tracking_params(:tracking_params)
    |> calculate_duration()
    |> unique_constraint(:uid)
    |> unique_constraint(:calendar_uid)
    |> UniqueSlot.constrain()
    |> check_constraint(:end_time, name: :meetings_end_after_start)
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:booking_page_id)
    |> UniqueInvitation.constrain()
  end

  # A new meeting gets its own calendar identity, generated independently of
  # `uid` so that nothing readable in a calendar leads back to the capability.
  # A UUID, like `uid`, because callers tell a Tymeslot-minted identifier from
  # one a provider assigned by that shape (`CalendarEventSync`'s legacy
  # mapping check, the Exchange busy-interval namespace). An existing meeting
  # already has one and keeps it: its event is keyed by it, and a new value
  # would orphan that event.
  defp ensure_calendar_uid(changeset) do
    case get_field(changeset, :calendar_uid) do
      nil -> put_change(changeset, :calendar_uid, UUID.generate())
      _present -> changeset
    end
  end

  defp ensure_seen_calendar_end(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = cs),
    do: put_change(cs, :seen_calendar_end_time, get_field(cs, :end_time))

  defp ensure_seen_calendar_end(changeset), do: changeset

  # Derives the duration from the times unless the caller gave one.
  defp calculate_duration(changeset) do
    with nil <- get_change(changeset, :duration),
         %DateTime{} = start_time <- get_field(changeset, :start_time),
         %DateTime{} = end_time <- get_field(changeset, :end_time) do
      put_change(changeset, :duration, DateTime.diff(end_time, start_time, :minute))
    else
      _given_or_incomplete -> changeset
    end
  end
end
