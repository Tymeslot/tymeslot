defmodule Tymeslot.BookingPages.BookingPageMeetingTypeSchema do
  @moduledoc """
  A meeting type listed on an extra booking page.

  Listing on the profile's own page at `/<username>` is not a row here: it
  stays `meeting_types.is_private == false`, as before pages existed.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          booking_page_id: integer() | nil,
          meeting_type_id: integer() | nil,
          booking_page: BookingPageSchema.t() | Ecto.Association.NotLoaded.t(),
          meeting_type: MeetingTypeSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "booking_page_meeting_types" do
    belongs_to(:booking_page, BookingPageSchema)
    belongs_to(:meeting_type, MeetingTypeSchema)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:booking_page_id, :meeting_type_id])
    |> validate_required([:booking_page_id, :meeting_type_id])
    |> foreign_key_constraint(:booking_page_id)
    |> foreign_key_constraint(:meeting_type_id)
    |> unique_constraint([:booking_page_id, :meeting_type_id])
  end
end
