defmodule Tymeslot.BookingPages do
  @moduledoc """
  Booking pages: extra public start pages of a profile, each at its own
  top-level address with its own theme, colours, texts and meeting types.

  The profile's own page at `/<username>` is not one of these; it stays on the
  profile. An address shares one namespace with usernames and reserved paths,
  so neither can take the other's.
  """
  alias Ecto.Changeset
  alias Tymeslot.BookingPages.BookingPageQueries
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes.GroupAccess
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog

  @type page :: BookingPageSchema.t()

  @max_pages 10

  # The page settings a page carries in place of its owner's.
  @page_settings [
    :booking_theme,
    :booking_text_enabled,
    :booking_heading,
    :booking_greeting,
    :booking_instruction
  ]

  @doc "The most extra pages one profile may hold."
  @spec max_pages() :: pos_integer()
  def max_pages, do: @max_pages

  @doc """
  `profile` as `page` presents it: the page's theme and booking texts in place
  of the profile's, and the page itself under the virtual `:booking_page`.
  Name, photo, timezone, username and embed domains stay the profile's.

  Everything that renders a start page reads these fields off the profile, so
  it renders the page without knowing pages exist. Never persist the result.
  """
  @spec apply_to_profile(ProfileSchema.t(), page()) :: ProfileSchema.t()
  def apply_to_profile(%ProfileSchema{} = profile, %BookingPageSchema{} = page) do
    profile
    |> struct(Map.take(page, @page_settings))
    |> Map.put(:booking_page, page)
  end

  @doc """
  The owner's profile, as the page at `address` presents it, or nil when no
  page has that address. Callers try usernames first.
  """
  @spec profile_for_address(String.t()) :: ProfileSchema.t() | nil
  def profile_for_address(address) when is_binary(address) do
    case page_at(address, [:profile]) do
      nil -> nil
      page -> apply_to_profile(page.profile, page)
    end
  end

  @doc """
  `profile_for_address/1` with the owner's user preloaded, as the scheduling
  flow's organiser context needs it.
  """
  @spec resolve_with_user(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def resolve_with_user(address) when is_binary(address) do
    case page_at(address, profile: :user) do
      nil -> {:error, :not_found}
      page -> {:ok, apply_to_profile(page.profile, page)}
    end
  end

  # A page is found whatever the case of its address, a username only as
  # typed (usernames are stored lowercase). So the caller's username lookup
  # misses `/Clash` for the username `clash`, and the username has to win
  # here instead, as it does at `/clash`.
  defp page_at(address, preload) do
    lowercase = String.downcase(address)

    if address != lowercase and match?({:ok, _profile}, ProfileQueries.get_by_username(lowercase)),
      do: nil,
      else: BookingPageQueries.get_by_slug(address, preload)
  end

  @doc """
  The address a profile's start page is at: its page's for a profile resolved
  through a page, otherwise its username.
  """
  @spec public_address(map() | nil) :: String.t() | nil
  def public_address(%{booking_page: %BookingPageSchema{slug: slug}}), do: slug
  def public_address(%{username: username}), do: username
  def public_address(_no_profile), do: nil

  @doc "A page as the dashboard lists it: its name, then its address."
  @spec name_and_address(page()) :: String.t()
  def name_and_address(%BookingPageSchema{name: name, slug: slug}), do: "#{name} · /#{slug}"

  @doc "The page a profile was resolved through, by id, or nil."
  @spec page_id(map() | nil) :: integer() | nil
  def page_id(%{booking_page: %BookingPageSchema{id: id}}), do: id
  def page_id(_profile), do: nil

  @doc """
  `id` when that page still exists, otherwise nil: a booking keeps the page it
  came through only while there is one, so a page deleted while its visitor
  was on the booking form is dropped from the booking. This is a check before
  the booking is written, not a guarantee: a page deleted between the check
  and the insert still fails that booking on the foreign key.
  """
  @spec existing_id(integer() | nil) :: integer() | nil
  def existing_id(id) when is_integer(id),
    do: if(BookingPageQueries.exists?(id), do: id, else: nil)

  def existing_id(_none), do: nil

  @doc "A profile's pages, oldest first."
  @spec list(integer()) :: [page()]
  def list(profile_id), do: BookingPageQueries.list_for_profile(profile_id)

  @doc """
  One of a profile's pages. `id` may come straight from a URL or an event, so
  a string that is not a whole number is simply not found.
  """
  @spec fetch(integer(), integer() | String.t()) :: {:ok, page()} | {:error, :not_found}
  def fetch(profile_id, id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> fetch(profile_id, int)
      _not_an_id -> {:error, :not_found}
    end
  end

  def fetch(profile_id, id) when is_integer(id) do
    case BookingPageQueries.get_for_profile(profile_id, id) do
      nil -> {:error, :not_found}
      page -> {:ok, page}
    end
  end

  @doc """
  The new-page form's changeset, address namespace included, for showing
  errors while the host types.
  """
  @spec change_new(ProfileSchema.t(), map()) :: Changeset.t()
  def change_new(%ProfileSchema{} = profile, attrs) do
    profile
    |> new_changeset(attrs)
    |> Map.put(:action, :validate)
  end

  @doc """
  Creates a page for `profile` on the profile's current theme, with copies of
  its colours (`ThemeCustomizations.copy_to_page/2`). Texts start switched off
  and no meeting types are listed.
  """
  @spec create(ProfileSchema.t(), map()) ::
          {:ok, page()} | {:error, :limit_reached} | {:error, Changeset.t()}
  def create(%ProfileSchema{} = profile, attrs) do
    if BookingPageQueries.count_for_profile(profile.id) >= @max_pages do
      {:error, :limit_reached}
    else
      Repo.transaction(fn ->
        with {:ok, page} <- profile |> new_changeset(attrs) |> BookingPageQueries.insert(),
             :ok <- ThemeCustomizations.copy_to_page(profile.id, page.id) do
          page
        else
          {:error, error} -> Repo.rollback(error)
        end
      end)
    end
  end

  @doc "The details form's changeset, address namespace included."
  @spec change_details(page(), map()) :: Changeset.t()
  def change_details(%BookingPageSchema{} = page, attrs) do
    page
    |> BookingPageSchema.details_changeset(attrs)
    |> validate_address_free(page.slug)
    |> Map.put(:action, :validate)
  end

  @doc """
  Renames a page or moves it to another address. A page deleted meanwhile, say
  in another tab, is not found, as `fetch/2` would report it.
  """
  @spec update_details(page(), map()) ::
          {:ok, page()} | {:error, :not_found} | {:error, Changeset.t()}
  def update_details(%BookingPageSchema{} = page, attrs) do
    page
    |> BookingPageSchema.details_changeset(attrs)
    |> validate_address_free(page.slug)
    |> BookingPageQueries.update()
    |> not_found_when_gone()
  end

  # `BookingPageQueries.update/1` reports a vanished row as a stale `:id`.
  defp not_found_when_gone({:error, %Changeset{errors: errors}} = result) do
    case errors[:id] do
      {_message, opts} -> if opts[:stale], do: {:error, :not_found}, else: result
      nil -> result
    end
  end

  defp not_found_when_gone(result), do: result

  @doc "Switches a page to another theme."
  @spec update_theme(page(), String.t()) :: {:ok, page()} | {:error, Changeset.t()}
  def update_theme(%BookingPageSchema{} = page, theme_id) do
    page
    |> BookingPageSchema.theme_changeset(theme_id)
    |> BookingPageQueries.update()
  end

  @doc """
  Saves a page's booking texts, under the rules the profile's own follow
  (`ProfileSchema.booking_text_changeset/2`). A page deleted meanwhile is not
  found, as in `update_details/2`.
  """
  @spec update_booking_text(page(), map()) ::
          {:ok, page()} | {:error, :not_found} | {:error, Changeset.t()}
  def update_booking_text(%BookingPageSchema{} = page, attrs) do
    page
    |> ProfileSchema.booking_text_changeset(attrs)
    |> BookingPageQueries.update()
    |> not_found_when_gone()
  end

  @doc """
  Deletes a page. Its colours go first, through `ThemeCustomizations`, so
  their uploaded background files are removed too; the database would drop the
  rows on its own but leave the files behind. Its meeting type listings go
  with the page, and its bookings keep everything but the page id.
  """
  @spec delete(page()) :: {:ok, page()} | {:error, term()}
  def delete(%BookingPageSchema{} = page) do
    with :ok <- ThemeCustomizations.delete_page_customizations(page.id) do
      BookingPageQueries.delete(page)
    end
  end

  @doc """
  Lists `meeting_type_id` on `page` or takes it off. Listing checks in the
  query that the type is the page owner's: another account's type, a missing
  one, or a page deleted meanwhile is `{:error, :not_found}`.
  """
  @spec set_meeting_type(page(), integer(), boolean()) :: :ok | {:error, term()}
  def set_meeting_type(%BookingPageSchema{id: page_id}, meeting_type_id, true),
    do: BookingPageQueries.add_meeting_type(page_id, meeting_type_id)

  def set_meeting_type(%BookingPageSchema{id: page_id}, meeting_type_id, false),
    do: BookingPageQueries.remove_meeting_type(page_id, meeting_type_id)

  @doc """
  The meeting types `page` offers on its start page: listed on it, active, and
  not a paused group type, as `MeetingTypes.get_public_meeting_types/1` treats
  the profile's own page.
  """
  @spec list_meeting_types(page()) :: [Tymeslot.MeetingTypes.MeetingTypeSchema.t()]
  def list_meeting_types(%BookingPageSchema{id: page_id}) do
    page_id
    |> BookingPageQueries.list_meeting_types()
    |> GroupAccess.reject_paused()
  end

  @doc """
  Which extra pages each of the profile's meeting types is listed on. A type
  on none of them has no key.
  """
  @spec memberships(integer()) :: %{optional(integer()) => MapSet.t(integer())}
  def memberships(profile_id) do
    profile_id
    |> BookingPageQueries.memberships_for_profile()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {type_id, page_ids} -> {type_id, MapSet.new(page_ids)} end)
  end

  defp new_changeset(profile, attrs) do
    %BookingPageSchema{}
    |> BookingPageSchema.create_changeset(
      Map.merge(stringify(attrs), %{
        "profile_id" => profile.id,
        "booking_theme" => profile.booking_theme || Catalog.default_id()
      })
    )
    |> validate_address_free(nil)
  end

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  @doc """
  `profile` as the page `meeting` was booked through presents it, while that
  page exists; otherwise `profile` unchanged (nil for a missing profile).
  Managing a booking (cancel, reschedule) and returning from its payment
  happen in the look the booking was made in, whichever address the link
  came in on.
  """
  @spec for_meeting(ProfileSchema.t() | nil, map()) :: ProfileSchema.t() | nil
  def for_meeting(%ProfileSchema{} = profile, %{booking_page_id: page_id})
      when is_integer(page_id) do
    case BookingPageQueries.get_for_profile(profile.id, page_id) do
      nil -> profile
      page -> apply_to_profile(profile, page)
    end
  end

  def for_meeting(profile, _meeting), do: profile

  @doc """
  The address to send someone back to for `meeting`: its page's while the
  page exists, otherwise `fallback` (the host's username).
  """
  @spec address_for_meeting(map(), String.t() | nil) :: String.t() | nil
  def address_for_meeting(%{booking_page_id: page_id}, fallback) when is_integer(page_id) do
    case BookingPageQueries.get(page_id) do
      %BookingPageSchema{slug: slug} -> slug
      nil -> fallback
    end
  end

  def address_for_meeting(_meeting, fallback), do: fallback

  # The page's own current address is never a clash with itself. Otherwise
  # `Profiles.username_available?/1` answers for usernames and pages alike
  # (Task 4), case-insensitively; the unique index settles a race between
  # pages, and resolution lets a username win a race against a page.
  defp validate_address_free(changeset, current_slug) do
    Changeset.validate_change(changeset, :slug, fn :slug, slug ->
      cond do
        slug == current_slug -> []
        Profiles.username_available?(slug) -> []
        true -> [slug: {"has already been taken", validation: :unsafe_unique}]
      end
    end)
  end
end
