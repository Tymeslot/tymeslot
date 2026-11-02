defmodule Tymeslot.BookingPages.BookingPageRedirectQueries do
  @moduledoc """
  Database access for booking pages' former addresses.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.BookingPages.BookingPageRedirectSchema
  alias Tymeslot.Repo

  @doc "The former address `slug` of a profile, with its page loaded, or nil."
  @spec get(integer(), String.t()) :: BookingPageRedirectSchema.t() | nil
  def get(profile_id, slug) do
    query =
      from(r in BookingPageRedirectSchema,
        where: r.profile_id == ^profile_id and r.slug == ^slug,
        preload: [:booking_page]
      )

    Repo.one(query)
  end

  @doc """
  Records `slug` as a former address of the profile, leading to `page_id`
  (nil: to the profile's own page). A row already there for the slug is
  pointed at `page_id` instead.
  """
  @spec put(integer(), String.t(), integer() | nil) :: :ok
  def put(profile_id, slug, page_id) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      BookingPageRedirectSchema,
      [
        %{
          profile_id: profile_id,
          slug: slug,
          booking_page_id: page_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: [set: [booking_page_id: page_id, updated_at: now]],
      conflict_target: [:profile_id, :slug]
    )

    :ok
  end

  @doc "Forgets `slug` as a former address of the profile; one not recorded is a no-op."
  @spec delete(integer(), String.t()) :: :ok
  def delete(profile_id, slug) do
    Repo.delete_all(
      from(r in BookingPageRedirectSchema, where: r.profile_id == ^profile_id and r.slug == ^slug)
    )

    :ok
  end
end
