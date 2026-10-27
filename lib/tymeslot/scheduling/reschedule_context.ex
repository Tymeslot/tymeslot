defmodule Tymeslot.Scheduling.RescheduleContext do
  @moduledoc """
  The booking a reschedule page is moving, loaded once for the page by
  `Tymeslot.Scheduling.ThemeFlow.reschedule_context/2`, and everything the
  page starts from that it decides.

  One load for all of it, so the meeting type the page is pinned to, the
  location it opens on, the form's starting values, the answers carried over
  and the meeting the offered times leave out all describe the same state of
  the booking. The context is only built for a meeting the lookup proved is
  the organiser's and may still move; the submit asks the rules again
  whatever the page holds.

    * `:uid` - the uid of the meeting being moved.
    * `:meeting` - the meeting being moved.
    * `:meeting_type` - the type the reschedule is committed to, or `nil`
      when the meeting predates meeting types or its type has been deleted.
    * `:location_choice` - the location the meeting was booked at
      (`ThemeFlow.reschedule_location_choice/1`).
    * `:form_data` - the booking form's starting values: the attendee's
      own details.
  """

  @enforce_keys [:uid, :meeting, :location_choice, :form_data]
  defstruct [:uid, :meeting, :meeting_type, :location_choice, :form_data]

  @type location_choice :: %{
          option_id: String.t() | nil,
          phone: String.t() | nil,
          video_integration_id: integer() | nil,
          venue_id: integer() | nil,
          location: String.t() | nil,
          address_to_arrange: boolean()
        }

  @type t :: %__MODULE__{
          uid: String.t(),
          meeting: struct(),
          meeting_type: map() | nil,
          location_choice: location_choice(),
          form_data: %{String.t() => String.t()}
        }

  @doc "The context for `meeting`, whose type has resolved to `meeting_type`."
  @spec new(struct(), map() | nil) :: t()
  def new(meeting, meeting_type) do
    %__MODULE__{
      uid: meeting.uid,
      meeting: meeting,
      meeting_type: meeting_type,
      location_choice: %{
        option_id: meeting.location_option_id,
        phone: meeting.attendee_phone,
        video_integration_id: meeting.video_integration_id,
        venue_id: meeting.venue_id,
        location: meeting.location,
        address_to_arrange: meeting.address_to_arrange == true
      },
      form_data: %{
        "name" => meeting.attendee_name,
        "email" => meeting.attendee_email,
        "message" => meeting.attendee_message || ""
      }
    }
  end
end
