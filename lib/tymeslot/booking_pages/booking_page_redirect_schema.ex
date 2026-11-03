defmodule Tymeslot.BookingPages.BookingPageRedirectSchema do
  @moduledoc """
  A former address of one of a profile's booking pages, kept for good so a
  link handed out under it keeps working: `/<username>/<slug>` and everything
  under it lead to the page's current address, or to the profile's own page
  (`booking_page_id` nil) once the page is deleted.

  Addresses belong to their profile, so nobody else can ever claim one and
  a row never expires. It goes only when the owner gives the slug to a page
  or a meeting type again (`Tymeslot.BookingPages`).
  """
  use Ecto.Schema

  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Profiles.ProfileSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          slug: String.t() | nil,
          booking_page_id: integer() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t(),
          booking_page: BookingPageSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "booking_page_redirects" do
    field(:slug, :string)

    belongs_to(:profile, ProfileSchema)
    belongs_to(:booking_page, BookingPageSchema)

    timestamps(type: :utc_datetime)
  end
end
