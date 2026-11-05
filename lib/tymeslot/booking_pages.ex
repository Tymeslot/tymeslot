defmodule Tymeslot.BookingPages do
  @moduledoc """
  Booking pages: extra public start pages of a profile, each with its own
  theme, colours, texts and meeting types, at `/<username>/<slug>`.

  The profile's own page at `/<username>` is not one of these; it stays on the
  profile. `/<username>/<x>` is either one of the profile's pages or one of
  its meeting types on its own page, so a page's slug and a meeting type's
  effective slug never meet within one profile (`claim_meeting_type_slug/2`
  and the page writes check each other under `BookingPageQueries.lock_addresses/1`).
  Addresses are per profile, so a page's former slugs lead to it for good
  (`locate/2`).

  A page is a draft until it lists a meeting type it can offer
  (`published?/1`): its addresses answer as unknown, except to its owner's
  preview.

  Creating and changing pages may be a paid feature (`Access`): without it a
  host's pages stay published and may be deleted, but every other write is
  `{:error, :upgrade_required}`. Each write that changes what the dashboard
  shows of a profile's pages is broadcast to its owner's dashboards
  (`subscribe/1`).
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.BookingPages.Access
  alias Tymeslot.BookingPages.BookingPageQueries
  alias Tymeslot.BookingPages.BookingPageRedirectQueries
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.BookingPages.SlugSuggestion
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.PublicListing
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
  Whether `user_id` may create pages and change them (`Access`). Deleting a
  page needs no permission.
  """
  @spec editable?(integer()) :: boolean()
  def editable?(user_id), do: Access.allowed?(user_id)

  @doc "What a write refused for want of the feature tells the host (`Access`)."
  @spec locked_message() :: String.t()
  defdelegate locked_message, to: Access

  @doc "The address the new-page dialog suggests for `name` (`SlugSuggestion`)."
  @spec suggest_slug(String.t() | nil) :: String.t()
  def suggest_slug(name), do: SlugSuggestion.from_name(name)

  @doc """
  Subscribes the caller to the profile's page changes: a page created,
  renamed, moved, deleted or given other meeting types arrives as
  `{:booking_pages_changed, profile_id}`, so an open dashboard notices a
  change made in another tab.
  """
  @spec subscribe(integer()) :: :ok | {:error, term()}
  def subscribe(profile_id) when is_integer(profile_id),
    do: Phoenix.PubSub.subscribe(Tymeslot.PubSub, topic(profile_id))

  # Best effort: a lost notice leaves another tab stale until its next edit,
  # which reports a page gone, so it never fails the write.
  defp broadcast(profile_id) do
    _sent =
      Phoenix.PubSub.broadcast(
        Tymeslot.PubSub,
        topic(profile_id),
        {:booking_pages_changed, profile_id}
      )

    :ok
  end

  defp broadcast_ok({:ok, %BookingPageSchema{profile_id: profile_id}} = result) do
    broadcast(profile_id)
    result
  end

  defp broadcast_ok(result), do: result

  defp topic(profile_id), do: "booking_pages:#{profile_id}"

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
  What `/<username>/<slug>` is for `profile`, ignoring case:

    * `{:ok, page}`: one of its pages, draft or not (`published?/1`), with
      its stored, lowercase slug;
    * `{:moved, slug}`: a page's former address, which now leads to the
      page at `slug`, or to the profile's own page (`nil`) once that page
      was deleted;
    * `:error`: neither, so a meeting type's slug or nothing.
  """
  @spec locate(ProfileSchema.t(), String.t()) ::
          {:ok, page()} | {:moved, String.t() | nil} | :error
  def locate(%ProfileSchema{id: profile_id}, slug) when is_binary(slug) do
    with nil <- BookingPageQueries.get_by_slug(profile_id, slug),
         nil <- BookingPageRedirectQueries.get(profile_id, String.downcase(slug)) do
      :error
    else
      %BookingPageSchema{} = page -> {:ok, page}
      %{booking_page: %BookingPageSchema{slug: current}} -> {:moved, current}
      %{booking_page: nil} -> {:moved, nil}
    end
  end

  @doc """
  The profile at `username`, with its user, as its page at `slug` presents
  it, draft or not. The scheduling flow's organiser context, once the
  address has been settled (`locate/2`).
  """
  @spec resolve_with_user(String.t(), String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, :not_found}
  def resolve_with_user(username, slug) when is_binary(username) and is_binary(slug) do
    with {:ok, profile} <- ProfileQueries.get_by_username_with_user(username),
         %BookingPageSchema{} = page <- BookingPageQueries.get_by_slug(profile.id, slug) do
      {:ok, apply_to_profile(profile, page)}
    else
      _no_profile_or_page -> {:error, :not_found}
    end
  end

  @doc """
  Whether `page` is public: it offers at least one meeting type
  (`list_meeting_types/1`). A page that offers none is a draft, which only
  its owner sees, through the dashboard's preview.
  """
  @spec published?(page()) :: boolean()
  def published?(%BookingPageSchema{} = page), do: list_meeting_types(page) != []

  @doc """
  The address a profile's start page is at, without the leading slash: its
  username, or `<username>/<slug>` for a profile resolved through a page.
  """
  @spec public_address(map() | nil) :: String.t() | nil
  def public_address(%{booking_page: %BookingPageSchema{slug: slug}, username: username})
      when is_binary(username),
      do: username <> "/" <> slug

  def public_address(%{username: username}), do: username
  def public_address(_no_profile), do: nil

  @doc "A page as the dashboard lists it: its name, then its address under `username`."
  @spec name_and_address(page(), String.t() | nil) :: String.t()
  def name_and_address(%BookingPageSchema{name: name, slug: slug}, username),
    do: "#{name} · /#{username}/#{slug}"

  @doc """
  The one address `meeting_type` is booked at, as a path: under the oldest
  page listing it when the profile's own page does not (`home_page/1`),
  otherwise `/<username>/<slug>`, which also serves a type listed nowhere
  as its direct link. `profile` is the owner's, through a page or not.
  """
  @spec meeting_type_path(map(), map()) :: String.t()
  def meeting_type_path(%{username: username}, meeting_type),
    do: path_under(username, home_page(meeting_type), meeting_type)

  @doc """
  `meeting_type_path/2` for each of `meeting_types`, by id, from one look at
  the profile's pages rather than one per type. For a list of types.
  """
  @spec meeting_type_paths(map(), [map()]) :: %{optional(integer()) => String.t()}
  def meeting_type_paths(%{id: profile_id} = profile, meeting_types),
    do: meeting_type_paths(profile, meeting_types, list(profile_id), memberships(profile_id))

  @doc """
  `meeting_type_paths/2` from the profile's pages, oldest first as `list/1`
  returns them, and their `memberships/1`, for a caller already holding both.
  """
  @spec meeting_type_paths(map(), [map()], [page()], map()) ::
          %{optional(integer()) => String.t()}
  def meeting_type_paths(%{username: username}, meeting_types, pages, memberships) do
    Map.new(meeting_types, fn type ->
      listed_on = Map.get(memberships, type.id, MapSet.new())
      home = if type.is_private, do: Enum.find(pages, &MapSet.member?(listed_on, &1.id))
      {type.id, path_under(username, home, type)}
    end)
  end

  defp path_under(username, nil, type),
    do: "/#{username}/#{MeetingTypes.effective_slug(type)}"

  defp path_under(username, %BookingPageSchema{slug: page_slug}, type),
    do: "/#{username}/#{page_slug}/#{MeetingTypes.effective_slug(type)}"

  @doc """
  The page `meeting_type` belongs to: the oldest page listing it, when it is
  hidden from the profile's own page (`is_private`). nil for a type the
  profile's own page lists, or one listed on no page at all.
  """
  @spec home_page(map()) :: page() | nil
  def home_page(%{is_private: true, id: id}) when is_integer(id),
    do: BookingPageQueries.first_for_meeting_type(id)

  def home_page(_listed_on_own_page), do: nil

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
  The new-page form's changeset, the slug checked against the profile's
  other pages and meeting types, for showing errors while the host types.
  """
  @spec change_new(ProfileSchema.t(), map()) :: Changeset.t()
  def change_new(%ProfileSchema{} = profile, attrs) do
    profile
    |> new_changeset(attrs)
    |> validate_slug_free(profile.id, profile.user_id, nil)
    |> Map.put(:action, :validate)
  end

  @doc """
  Creates a page for `profile` on the profile's current theme, with copies of
  its colours (`ThemeCustomizations.copy_to_page/2`). Texts start switched off
  and no meeting types are listed, so it starts as a draft (`published?/1`).
  Taking a slug the profile once had for another page ends that old
  address's redirect.
  """
  @spec create(ProfileSchema.t(), map()) ::
          {:ok, page()}
          | {:error, :limit_reached | :upgrade_required}
          | {:error, Changeset.t()}
  def create(%ProfileSchema{} = profile, attrs) do
    cond do
      Access.check(profile.user_id) != :ok ->
        {:error, :upgrade_required}

      BookingPageQueries.count_for_profile(profile.id) >= @max_pages ->
        {:error, :limit_reached}

      true ->
        do_create(profile, attrs)
    end
  end

  defp do_create(profile, attrs) do
    broadcast_ok(
      Repo.transaction(fn ->
        :ok = BookingPageQueries.lock_addresses(profile.id)

        with {:ok, page} <-
               profile
               |> new_changeset(attrs)
               |> validate_slug_free(profile.id, profile.user_id, nil)
               |> BookingPageQueries.insert(),
             :ok <- BookingPageRedirectQueries.delete(profile.id, page.slug),
             :ok <- ThemeCustomizations.copy_to_page(profile.id, page.id) do
          page
        else
          {:error, error} -> Repo.rollback(error)
        end
      end)
    )
  end

  @doc "The details form's changeset, the slug checked as `change_new/2` checks it."
  @spec change_details(page(), map()) :: Changeset.t()
  def change_details(%BookingPageSchema{} = page, attrs) do
    page
    |> BookingPageSchema.details_changeset(attrs)
    |> validate_slug_free(
      page.profile_id,
      ProfileQueries.user_id_for_profile(page.profile_id),
      page.id
    )
    |> Map.put(:action, :validate)
  end

  @doc """
  Renames a page or moves it to another slug. The slug it leaves keeps
  leading to the page (`locate/2`), and the one it takes stops leading
  anywhere else. A page deleted meanwhile, say in another tab, is not found,
  as `fetch/2` would report it.
  """
  @spec update_details(page(), map()) ::
          {:ok, page()} | {:error, :not_found | :upgrade_required} | {:error, Changeset.t()}
  def update_details(%BookingPageSchema{} = page, attrs) do
    with :ok <- Access.check_profile(page.profile_id) do
      page |> do_update_details(attrs) |> broadcast_ok()
    end
  end

  defp do_update_details(page, attrs) do
    result =
      Repo.transaction(fn ->
        :ok = BookingPageQueries.lock_addresses(page.profile_id)
        user_id = ProfileQueries.user_id_for_profile(page.profile_id)

        page
        |> BookingPageSchema.details_changeset(attrs)
        |> validate_slug_free(page.profile_id, user_id, page.id)
        |> BookingPageQueries.update()
        |> ok_or_rollback()
        |> record_move(page.slug)
      end)

    not_found_when_gone(result)
  end

  defp record_move(%BookingPageSchema{slug: same} = page, same), do: page

  defp record_move(%BookingPageSchema{} = page, old_slug) do
    :ok = BookingPageRedirectQueries.delete(page.profile_id, page.slug)
    :ok = BookingPageRedirectQueries.put(page.profile_id, old_slug, page.id)
    page
  end

  defp ok_or_rollback({:ok, value}), do: value
  defp ok_or_rollback({:error, reason}), do: Repo.rollback(reason)

  # `BookingPageQueries.update/1` reports a vanished row as a stale `:id`.
  defp not_found_when_gone({:error, %Changeset{errors: errors}} = result) do
    case errors[:id] do
      {_message, opts} -> if opts[:stale], do: {:error, :not_found}, else: result
      nil -> result
    end
  end

  defp not_found_when_gone(result), do: result

  @doc "Switches a page to another theme."
  @spec update_theme(page(), String.t()) ::
          {:ok, page()} | {:error, :upgrade_required} | {:error, Changeset.t()}
  def update_theme(%BookingPageSchema{} = page, theme_id) do
    with :ok <- Access.check_profile(page.profile_id) do
      page
      |> BookingPageSchema.theme_changeset(theme_id)
      |> BookingPageQueries.update()
    end
  end

  @doc """
  Saves a page's booking texts, under the rules the profile's own follow
  (`ProfileSchema.booking_text_changeset/2`). A page deleted meanwhile is not
  found, as in `update_details/2`.
  """
  @spec update_booking_text(page(), map()) ::
          {:ok, page()} | {:error, :not_found | :upgrade_required} | {:error, Changeset.t()}
  def update_booking_text(%BookingPageSchema{} = page, attrs) do
    with :ok <- Access.check_profile(page.profile_id) do
      page
      |> ProfileSchema.booking_text_changeset(attrs)
      |> BookingPageQueries.update()
      |> not_found_when_gone()
    end
  end

  @doc """
  Deletes a page, its colours and their uploaded background files. Its meeting
  type listings go with the page, and its bookings keep everything but the
  page id. Its address, and every former one, then lead to the profile's own
  page. A page already gone counts as deleted. Allowed with or without the
  feature (`Access`), so a host who lost it can still tidy up.

  The page is locked first, so a colour saved in another tab either lands
  before the delete (and goes with it) or fails on the missing page, never
  between. The colour rows and the page go in one transaction; the files only
  once it has committed, so a failed delete leaves the page whole.
  """
  @spec delete(page()) :: {:ok, page()} | {:error, term()}
  def delete(%BookingPageSchema{} = page) do
    result =
      Repo.transaction(fn ->
        case BookingPageQueries.lock(page.id) do
          nil ->
            {page, []}

          %BookingPageSchema{} = current ->
            customizations = ThemeCustomizations.delete_page_customizations(page.id)
            deleted = page |> BookingPageQueries.delete() |> ok_or_rollback()
            # The former addresses' rows lose the page by the foreign key.
            :ok = BookingPageRedirectQueries.put(current.profile_id, current.slug, nil)
            {deleted, customizations}
        end
      end)

    with {:ok, {deleted, customizations}} <- result do
      ThemeCustomizations.cleanup_page_files(customizations)
      broadcast(page.profile_id)
      {:ok, deleted}
    end
  end

  @doc """
  Lists `meeting_type_id` on `page` or takes it off. Listing checks in the
  query that the type is the page owner's: another account's type, a missing
  one, or a page deleted meanwhile is `{:error, :not_found}`, and an account
  without the feature (`Access`) `{:error, :upgrade_required}`.
  """
  @spec set_meeting_type(page(), integer(), boolean()) :: :ok | {:error, term()}
  def set_meeting_type(%BookingPageSchema{} = page, meeting_type_id, listed?) do
    with :ok <- Access.check_profile(page.profile_id),
         :ok <- write_listing(page.id, meeting_type_id, listed?) do
      broadcast(page.profile_id)
    end
  end

  defp write_listing(page_id, meeting_type_id, true),
    do: BookingPageQueries.add_meeting_type(page_id, meeting_type_id)

  defp write_listing(page_id, meeting_type_id, false),
    do: BookingPageQueries.remove_meeting_type(page_id, meeting_type_id)

  @doc """
  The meeting types `page` alone lists: hidden from the profile's own page
  and on no other page, so deleting `page` leaves them unlisted everywhere,
  bookable only by their direct links. In the profile's order.
  """
  @spec only_listed_on(page()) :: [Tymeslot.MeetingTypes.MeetingTypeSchema.t()]
  def only_listed_on(%BookingPageSchema{id: page_id} = page) do
    memberships = memberships(page.profile_id)
    sole = MapSet.new([page_id])

    page.profile_id
    |> ProfileQueries.user_id_for_profile()
    |> MeetingTypes.get_all_meeting_types()
    |> Enum.filter(&(&1.is_private and Map.get(memberships, &1.id) == sole))
  end

  @doc """
  The meeting types `page` offers on its start page: listed on it and active,
  then filtered and ordered as `MeetingTypes.get_public_meeting_types/1` treats
  the profile's own page (`Tymeslot.MeetingTypes.PublicListing`).
  """
  @spec list_meeting_types(page()) :: [Tymeslot.MeetingTypes.MeetingTypeSchema.t()]
  def list_meeting_types(%BookingPageSchema{id: page_id}) do
    page_id
    |> BookingPageQueries.list_meeting_types()
    |> PublicListing.offered()
  end

  @doc """
  Whether `page` serves `meeting_type` at `/<username>/<page>/<slug>`: the
  type is listed on it, or it is unlisted everywhere (hidden from
  `/<username>` and on no page), so its direct link is the only way in and
  any of the host's addresses may carry it. A type listed only on
  `/<username>` or on other pages belongs to its own address
  (`meeting_type_path/2`), and booking it here would record this page
  against a type it does not offer.
  """
  @spec serves?(page(), map()) :: boolean()
  def serves?(%BookingPageSchema{id: page_id}, %{id: type_id, is_private: private?})
      when is_integer(type_id) do
    case BookingPageQueries.page_ids_for_meeting_type(type_id) do
      [] -> private? == true
      page_ids -> page_id in page_ids
    end
  end

  def serves?(_page, _meeting_type), do: false

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
    BookingPageSchema.create_changeset(
      %BookingPageSchema{},
      Map.merge(stringify(attrs), %{
        "profile_id" => profile.id,
        "booking_theme" => profile.booking_theme || Catalog.default_id()
      })
    )
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
  The address, without the leading slash, to send someone back to for
  `meeting`: `<username>/<page>` while the page it came through exists and
  is public, otherwise `username` (the host's own page).
  """
  @spec address_for_meeting(map(), String.t() | nil) :: String.t() | nil
  def address_for_meeting(%{booking_page_id: page_id}, username)
      when is_integer(page_id) and is_binary(username) do
    with %BookingPageSchema{} = page <- BookingPageQueries.get(page_id),
         true <- published?(page) do
      username <> "/" <> page.slug
    else
      _gone_or_draft -> username
    end
  end

  def address_for_meeting(_meeting, username), do: username

  @doc """
  Claims `slug` as a meeting type's address for `user_id`'s profile, inside
  the caller's transaction: refused when one of the profile's pages holds
  it, and otherwise ending the redirect a former page address of that slug
  had. Serialised with the page writes (`BookingPageQueries.lock_addresses/1`).
  A user without a profile has no pages, so anything is free.
  """
  @spec claim_meeting_type_slug(integer(), String.t()) :: :ok | {:error, :taken_by_page}
  def claim_meeting_type_slug(user_id, slug) when is_integer(user_id) and is_binary(slug) do
    case ProfileQueries.id_for_user(user_id) do
      nil ->
        :ok

      profile_id ->
        :ok = BookingPageQueries.lock_addresses(profile_id)

        if BookingPageQueries.slug_taken?(profile_id, slug),
          do: {:error, :taken_by_page},
          else: BookingPageRedirectQueries.delete(profile_id, String.downcase(slug))
    end
  end

  # The slug must be free of the profile's other pages (the unique index is
  # the backstop) and of its meeting types' effective slugs, which share the
  # second segment of `/<username>/<x>`. Writes call this under
  # `BookingPageQueries.lock_addresses/1`.
  defp validate_slug_free(changeset, profile_id, user_id, page_id) do
    Changeset.validate_change(changeset, :slug, fn :slug, slug ->
      cond do
        is_integer(profile_id) and BookingPageQueries.slug_taken?(profile_id, slug, page_id) ->
          [slug: {"has already been taken", validation: :unsafe_unique}]

        is_integer(user_id) and MeetingTypes.slug_in_use?(user_id, slug) ->
          [slug: {meeting_type_clash_message(), validation: :meeting_type_slug}]

        true ->
          []
      end
    end)
  end

  # Built at call time so it follows the caller's locale.
  defp meeting_type_clash_message,
    do: dgettext("errors", "is already the address of one of your meeting types")
end
