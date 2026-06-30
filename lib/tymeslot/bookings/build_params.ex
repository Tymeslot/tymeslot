defmodule Tymeslot.Bookings.BuildParams do
  @moduledoc """
  Typed parameters for `Tymeslot.Bookings.Policy.build_meeting_attributes/1`.

  Carrying the booking inputs as a struct rather than a loose map lets the
  meeting-attribute builder narrow each field's type, so the precise
  `Tymeslot.Bookings.Policy.meeting_attributes/0` contract can be verified by
  Dialyzer instead of collapsing to `term()`.
  """

  @enforce_keys [:meeting_uid, :form_data, :start_datetime, :end_datetime, :duration_minutes]
  defstruct [
    :meeting_uid,
    :form_data,
    :start_datetime,
    :end_datetime,
    :duration_minutes,
    :user_timezone,
    :organizer_user_id,
    :meeting_type_id,
    :video_integration_id,
    :attendee_locale,
    :utm_source,
    :utm_medium,
    :utm_campaign,
    :utm_content,
    :utm_term,
    :referrer_host,
    :visitor_hash,
    custom_fields_snapshot: [],
    custom_field_answers: %{},
    tracking_params: %{}
  ]

  @type t :: %__MODULE__{
          meeting_uid: String.t(),
          form_data: %{optional(String.t()) => term()},
          start_datetime: DateTime.t(),
          end_datetime: DateTime.t(),
          duration_minutes: integer(),
          user_timezone: String.t() | nil,
          organizer_user_id: integer() | nil,
          meeting_type_id: integer() | nil,
          video_integration_id: integer() | String.t() | nil,
          attendee_locale: String.t() | nil,
          utm_source: String.t() | nil,
          utm_medium: String.t() | nil,
          utm_campaign: String.t() | nil,
          utm_content: String.t() | nil,
          utm_term: String.t() | nil,
          referrer_host: String.t() | nil,
          visitor_hash: String.t() | nil,
          custom_fields_snapshot: [map()],
          custom_field_answers: map(),
          tracking_params: map()
        }

  @doc """
  Builds a `t/0` from the booking-data map assembled during booking creation.

  Keys not part of the struct (e.g. `:date`, `:guest_emails`) are ignored, so
  the broader `booking_data` map can be handed in directly. `struct/2` (not
  `struct!/2`) is used precisely because the booking-data map carries those
  extra keys, which `struct!/2` would reject.
  """
  @spec new(map()) :: t()
  def new(booking_data) when is_map(booking_data), do: struct(__MODULE__, booking_data)
end
