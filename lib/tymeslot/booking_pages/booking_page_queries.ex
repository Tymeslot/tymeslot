defmodule Tymeslot.BookingPages.BookingPageQueries do
  @moduledoc """
  Database access for booking pages.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.BookingPages.BookingPageMeetingTypeSchema
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @doc "A profile's pages, oldest first."
  @spec list_for_profile(integer()) :: [BookingPageSchema.t()]
  def list_for_profile(profile_id) do
    query =
      from(p in BookingPageSchema,
        where: p.profile_id == ^profile_id,
        order_by: [asc: p.inserted_at, asc: p.id]
      )

    Repo.all(query)
  end

  @doc "How many pages a profile holds."
  @spec count_for_profile(integer()) :: non_neg_integer()
  def count_for_profile(profile_id) do
    query = from(p in BookingPageSchema, where: p.profile_id == ^profile_id)
    Repo.aggregate(query, :count)
  end

  @doc "One of a profile's pages, scoped so an id can never reach another profile's."
  @spec get_for_profile(integer(), integer()) :: BookingPageSchema.t() | nil
  def get_for_profile(profile_id, id),
    do: Repo.get_by(BookingPageSchema, id: id, profile_id: profile_id)

  @doc """
  The page with `id`, locked `FOR UPDATE` until the surrounding transaction
  ends, or nil when it is gone. Holding it keeps any write that references the
  page (a new colour row, a listing) waiting until the transaction ends.
  """
  @spec lock(integer()) :: BookingPageSchema.t() | nil
  def lock(id), do: Repo.one(from(p in BookingPageSchema, where: p.id == ^id, lock: "FOR UPDATE"))

  @doc "A page by id."
  @spec get(integer()) :: BookingPageSchema.t() | nil
  def get(id), do: Repo.get(BookingPageSchema, id)

  @doc """
  The profile's page at `slug`, with `preload` loaded. Compared lowercase so
  the `(profile_id, lower(slug))` index is used.
  """
  @spec get_by_slug(integer(), String.t(), list()) :: BookingPageSchema.t() | nil
  def get_by_slug(profile_id, slug, preload \\ []) do
    normalised = String.downcase(slug)

    query =
      from(p in BookingPageSchema,
        where: p.profile_id == ^profile_id and fragment("lower(?)", p.slug) == ^normalised,
        preload: ^preload
      )

    Repo.one(query)
  end

  @doc """
  Whether another of the profile's pages than `except_id` (nil: any page)
  holds `slug`, ignoring case, as the unique index does.
  """
  @spec slug_taken?(integer(), String.t(), integer() | nil) :: boolean()
  def slug_taken?(profile_id, slug, except_id \\ nil) do
    normalised = String.downcase(slug)

    query =
      from(p in BookingPageSchema,
        where: p.profile_id == ^profile_id and fragment("lower(?)", p.slug) == ^normalised
      )

    query = if except_id, do: where(query, [p], p.id != ^except_id), else: query

    Repo.exists?(query)
  end

  # Distinguishes the address lock from any other advisory locks the
  # application takes. Arbitrary but must stay stable.
  @address_lock_class 715_003

  @doc """
  Serialises, within the current transaction, every write that gives one of
  the profile's pages or meeting types an address (`pg_advisory_xact_lock/2`
  keyed on the profile). Pages and meeting types share the second segment
  of `/<username>/<x>` but live in two tables, so no unique index can keep
  them apart: each write takes this lock first and checks the other table
  under it. Released on commit or rollback. Must be called inside a
  transaction.
  """
  @spec lock_addresses(integer()) :: :ok
  def lock_addresses(profile_id) when is_integer(profile_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@address_lock_class, profile_id])
    :ok
  end

  @doc "The oldest page `meeting_type_id` is listed on, or nil when it is on none."
  @spec first_for_meeting_type(integer()) :: BookingPageSchema.t() | nil
  def first_for_meeting_type(meeting_type_id) do
    query =
      from(p in BookingPageSchema,
        join: l in BookingPageMeetingTypeSchema,
        on: l.booking_page_id == p.id,
        where: l.meeting_type_id == ^meeting_type_id,
        order_by: [asc: p.inserted_at, asc: p.id],
        limit: 1
      )

    Repo.one(query)
  end

  @doc "Whether a page with `id` exists on a profile of the user `user_id`."
  @spec exists_for_user?(integer(), integer()) :: boolean()
  def exists_for_user?(id, user_id) do
    query =
      from(p in BookingPageSchema,
        join: pr in ProfileSchema,
        on: pr.id == p.profile_id,
        where: p.id == ^id and pr.user_id == ^user_id
      )

    Repo.exists?(query)
  end

  @doc """
  Lists a meeting type on a page; listing it again is a no-op. The row is
  inserted only if the type belongs to the user who owns the page's profile,
  so a type id from another account, a missing type, or a page deleted
  meanwhile is `{:error, :not_found}` and inserts nothing.
  """
  @spec add_meeting_type(integer(), integer()) :: :ok | {:error, :not_found}
  def add_meeting_type(page_id, meeting_type_id) do
    now = DateTime.utc_now(:second)

    owned =
      from(p in BookingPageSchema,
        join: pr in ProfileSchema,
        on: pr.id == p.profile_id,
        join: mt in MeetingTypeSchema,
        on: mt.user_id == pr.user_id,
        where: p.id == ^page_id and mt.id == ^meeting_type_id,
        select: %{
          booking_page_id: p.id,
          meeting_type_id: mt.id,
          inserted_at: type(^now, :utc_datetime),
          updated_at: type(^now, :utc_datetime)
        }
      )

    {inserted, _rows} =
      Repo.insert_all(BookingPageMeetingTypeSchema, owned,
        on_conflict: :nothing,
        conflict_target: [:booking_page_id, :meeting_type_id]
      )

    if inserted == 1 or listed?(page_id, meeting_type_id), do: :ok, else: {:error, :not_found}
  end

  defp listed?(page_id, meeting_type_id) do
    Repo.exists?(
      from(l in BookingPageMeetingTypeSchema,
        where: l.booking_page_id == ^page_id and l.meeting_type_id == ^meeting_type_id
      )
    )
  end

  @doc "Takes a meeting type off a page; one not listed is a no-op."
  @spec remove_meeting_type(integer(), integer()) :: :ok
  def remove_meeting_type(page_id, meeting_type_id) do
    query =
      from(l in BookingPageMeetingTypeSchema,
        where: l.booking_page_id == ^page_id and l.meeting_type_id == ^meeting_type_id
      )

    Repo.delete_all(query)

    :ok
  end

  @doc """
  The active meeting types listed on a page, in the host's order, preloaded
  as `MeetingTypeQueries.list_public_meeting_types/1` preloads them. Only types
  owned by the page's profile's user are listed, so a stray listing row for
  someone else's type is never shown.
  """
  @spec list_meeting_types(integer()) :: [MeetingTypeSchema.t()]
  def list_meeting_types(page_id) do
    query =
      from(mt in MeetingTypeSchema,
        join: l in BookingPageMeetingTypeSchema,
        on: l.meeting_type_id == mt.id,
        join: p in BookingPageSchema,
        on: p.id == l.booking_page_id,
        join: pr in assoc(p, :profile),
        where: l.booking_page_id == ^page_id and mt.is_active == true,
        where: mt.user_id == pr.user_id,
        order_by: [asc: mt.sort_order, asc: mt.name],
        preload: [:video_integration, :calendar_integration]
      )

    Repo.all(query)
  end

  @doc "The ids of the pages a meeting type is listed on."
  @spec page_ids_for_meeting_type(integer()) :: [integer()]
  def page_ids_for_meeting_type(meeting_type_id) do
    query =
      from(l in BookingPageMeetingTypeSchema,
        where: l.meeting_type_id == ^meeting_type_id,
        select: l.booking_page_id
      )

    Repo.all(query)
  end

  @doc "Every `{meeting_type_id, page_id}` listing among a profile's pages."
  @spec memberships_for_profile(integer()) :: [{integer(), integer()}]
  def memberships_for_profile(profile_id) do
    query =
      from(l in BookingPageMeetingTypeSchema,
        join: p in BookingPageSchema,
        on: p.id == l.booking_page_id,
        where: p.profile_id == ^profile_id,
        select: {l.meeting_type_id, l.booking_page_id}
      )

    Repo.all(query)
  end

  @doc false
  @spec insert(Ecto.Changeset.t()) :: {:ok, BookingPageSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @doc """
  Saves a page. A page deleted meanwhile, say in another tab, is an error on
  `:id`, not a crash.
  """
  @spec update(Ecto.Changeset.t()) :: {:ok, BookingPageSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset), do: Repo.update(changeset, stale_error_field: :id)

  @doc "Deletes a page; one already gone counts as deleted."
  @spec delete(BookingPageSchema.t()) ::
          {:ok, BookingPageSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(page), do: Repo.delete(page, allow_stale: true)
end
