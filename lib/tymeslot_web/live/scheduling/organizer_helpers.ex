defmodule TymeslotWeb.Live.Scheduling.OrganizerHelpers do
  @moduledoc """
  Per-request organizer setup helpers for the scheduling flow.

  Owns the slice of socket state that does not depend on calendar
  availability: username resolution, the booking form, and the client
  IP captured at mount.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Phoenix.Component
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.BookingPages
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.Demo
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.OrganizerContext
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.BookingConfig

  import Component, only: [assign: 3]

  @default_booking_window_days 90

  @doc """
  Handles username resolution and organizer setup.
  """
  @spec handle_username_resolution(
          Phoenix.LiveView.Socket.t(),
          ProfileSchema.t() | String.t() | nil
        ) ::
          Phoenix.LiveView.Socket.t()
  def handle_username_resolution(socket, nil) do
    socket
    |> store_client_ip()
    |> assign(:username_context, nil)
    |> assign(:host_currency, nil)
  end

  # A booking URL's organiser, already settled by `PageAddress` with its user
  # and the page it presents: its context is built without looking it up
  # again. A username the demo overlay may claim still goes through it.
  def handle_username_resolution(socket, %ProfileSchema{username: username} = organiser) do
    if Demo.demo_username?(username),
      do: handle_username_resolution(socket, BookingPages.public_address(organiser)),
      else: assign_organizer_context(socket, {:ok, Profiles.organizer_context(organiser)})
  end

  def handle_username_resolution(socket, address) when is_binary(address),
    do: assign_organizer_context(socket, Demo.resolve_organizer_context(address))

  defp assign_organizer_context(socket, resolution) do
    # Store client IP during username resolution to ensure it's available later
    socket = store_client_ip(socket)

    case resolution do
      {:error, :profile_not_found} ->
        # During mount, we can't use put_flash/redirect - let the mount handle this
        socket
        |> assign(:username_context, nil)
        |> assign(:organizer_profile, nil)
        |> assign(:legal_links, Profiles.public_legal_links(nil))
        |> assign(:booking_window_days, booking_window_days(nil))
        |> assign(:organizer_user_id, nil)
        |> assign(:meeting_types, [])
        |> assign(:host_currency, nil)
        |> assign(:page_title, dgettext("errors", "Page not found"))

      {:ok, context} ->
        socket
        |> assign(:organizer_source, Map.take(context, [:profile, :meeting_types, :page_title]))
        |> assign_localised_organizer(nil)
        |> assign(:username_context, context.username)
        |> assign(:legal_links, Profiles.public_legal_links(context.profile))
        |> assign(:booking_window_days, booking_window_days(context.profile))
        |> assign(:organizer_user_id, context.user_id)
        |> assign(:host_currency, host_currency(context))
    end
  end

  @doc """
  Follows the language a meeting was booked in (`booked`, its
  `attendee_locale`) on that meeting's own pages, where it ranks below the
  visitor's own pick and above their browser
  (`Languages.visitor_locale/2`).

  The organiser was set up before the meeting was known; when the booked
  language changes the page's language, their texts are put into the new one
  again from the profile and meeting types `handle_username_resolution/2`
  kept as loaded, without looking the organiser up a second time.
  """
  @spec follow_booked_language(Phoenix.LiveView.Socket.t(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def follow_booked_language(socket, booked) do
    case socket.assigns[:organizer_source] do
      %{profile: profile} ->
        if Languages.visitor_locale(profile, language_preferences(socket, booked)) ==
             socket.assigns[:locale],
           do: socket,
           else: assign_localised_organizer(socket, booked)

      _no_organizer ->
        socket
    end
  end

  # The organiser's profile, meeting types and page title in the page's
  # language, from the organiser as loaded.
  defp assign_localised_organizer(socket, booked) do
    %{profile: raw_profile} = source = socket.assigns.organizer_source
    socket = assign_page_language(socket, raw_profile, booked)
    content_locale = socket.assigns.content_locale
    profile = ContentTranslations.localise(raw_profile, content_locale)

    socket
    |> assign(:organizer_profile, profile)
    |> assign(:meeting_types, ContentTranslations.localise(source.meeting_types, content_locale))
    |> assign(:page_title, page_title(profile, source))
  end

  @doc """
  Assigns a public page's language among the ones the organiser offers
  (`Languages.visitor_locale/2`): the visitor's own pick (`:locale_choice`),
  else the language the meeting was `booked` in, else the first of the
  browser's languages (`:browser_locales`) offered, else the organiser's
  original; a pick the organiser does not offer gives the original.

  Also assigns `:offered_locales`, which the language switcher lists,
  `:content_locale`, the language the organiser's texts are shown in (nil
  for the original), and `:stale_locale_param`, whether the pick set aside
  was the URL's own `?locale=` (`:locale_param`), which
  `TymeslotWeb.Themes.Shared.LocaleHandler` replaces by reloading. A
  remembered pick set aside is left as it is: the session's choice is shared
  by every organiser's pages, and another organiser may offer it.
  """
  @spec assign_page_language(Phoenix.LiveView.Socket.t(), map(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def assign_page_language(socket, profile, booked \\ nil) do
    preferences = language_preferences(socket, booked)
    locale = Languages.visitor_locale(profile, preferences)

    # Global: reaches every Gettext backend in this process, not just Core's.
    Gettext.put_locale(locale)

    socket
    |> assign(:locale, locale)
    |> assign(:offered_locales, Languages.offered(profile))
    |> assign(:content_locale, Languages.content_locale(profile, locale))
    |> assign(:stale_locale_param, stale_param?(socket, profile, preferences[:picked]))
  end

  defp stale_param?(socket, profile, picked) do
    picked != nil and picked == socket.assigns[:locale_param] and
      Languages.stale_pick?(profile, picked)
  end

  # A socket mounted without `TymeslotWeb.Hooks.LocaleHook` has only its
  # locale to go on.
  defp language_preferences(socket, booked) do
    [
      picked: socket.assigns[:locale_choice],
      booked: booked,
      browser: socket.assigns[:browser_locales] || List.wrap(socket.assigns[:locale])
    ]
  end

  # Built again in the page's language, with the page's translated name. A
  # demo persona's context brings its own.
  defp page_title(%ProfileSchema{} = profile, context) do
    if Demo.demo_profile?(profile),
      do: context.page_title,
      else: OrganizerContext.page_title(profile)
  end

  defp page_title(_demo_profile, context), do: context.page_title

  # The currency the organiser's paid meeting types are priced in, for the
  # steps that show a price (`BookingText.price_label/3`): the currency
  # checkout charges (`MeetingPayments.charge_currency/1`), even one outside
  # the allowlist that new prices can no longer be set in. Looked up only when
  # one of them is paid, so a page without a paid type costs no query. A demo
  # persona's meeting types are plain maps without the field.
  defp host_currency(%{user_id: user_id, meeting_types: meeting_types}) do
    if Enum.any?(meeting_types, &(Map.get(&1, :payment_required) == true)) do
      MeetingPayments.charge_currency(user_id)
    else
      nil
    end
  end

  @doc """
  Resolves the booking window, in days, to show a visitor for an organiser.

  The given meeting type's own window when it overrides one, else the window of
  the schedule it resolves to, falling back to the organiser's default schedule
  before a meeting type is chosen. It cannot be read from the default alone:
  this figure both advertises the window and disables the calendar's forward
  navigation, and a meeting type (or its schedule) may open a *longer* window
  than the default, whose dates would then be unreachable.

  Demo organisers are plain maps supplied by the overlay rather than persisted
  profiles, so they carry no schedule and are answered by the demo provider.
  """
  @spec booking_window_days(map() | nil, map() | nil) :: pos_integer()
  def booking_window_days(profile, meeting_type \\ nil)

  def booking_window_days(nil, _meeting_type), do: @default_booking_window_days

  def booking_window_days(profile, meeting_type) do
    if Demo.demo_profile?(profile) do
      Demo.booking_window_days(profile)
    else
      meeting_type
      |> Schedules.resolve_for(profile)
      |> Schedules.effective_policy(meeting_type, :advance_booking_days)
    end
  end

  @doc """
  Re-reads the booking window for whatever meeting type is now selected.

  Call after assigning `:meeting_type`; the window is first assigned at mount,
  when no meeting type has been picked yet.
  """
  @spec assign_booking_window(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_booking_window(socket) do
    assign(
      socket,
      :booking_window_days,
      booking_window_days(
        socket.assigns[:organizer_profile],
        socket.assigns[:meeting_type]
      )
    )
  end

  @doc "Initialises form, touched-field, validation-error, and saving assigns."
  @spec setup_form_state(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def setup_form_state(socket, form_data, opts) do
    as = Keyword.get(opts, :as)

    socket
    |> assign(:form, Component.to_form(form_data, as: as))
    |> assign(:touched_fields, MapSet.new())
    |> assign(:validation_errors, %{})
    |> assign(:saving, false)
  end

  @doc """
  Marks a form field as touched.
  """
  @spec mark_field_touched(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def mark_field_touched(socket, field_name) do
    assign(socket, :touched_fields, MapSet.put(socket.assigns.touched_fields, field_name))
  end

  # Stores client IP in socket assigns during mount, to capture the IP for
  # later use.
  @spec store_client_ip(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp store_client_ip(socket) do
    # Try mount-specific extraction first if not already in assigns
    ip =
      case socket.assigns[:client_ip] do
        ip when is_binary(ip) ->
          ip

        _other ->
          # get_from_mount/1 should only be called during mount.
          # We wrap it in try-rescue to prevent crashes if called during events.
          try do
            ClientIP.get_from_mount(socket)
          rescue
            exception ->
              # Debug rather than warning: this is the expected outcome whenever
              # the helper runs outside mount, which is why it is wrapped at all.
              Logger.debug("Client IP unavailable outside mount",
                error: Exception.message(exception)
              )

              "unknown"
          end
      end

    assign(socket, :client_ip, ip)
  end

  @doc """
  Validates if form is complete and valid.
  """
  @spec form_valid?(Phoenix.HTML.Form.t()) :: boolean()
  def form_valid?(%{source: source}) when is_map(source) do
    case InputProcessor.validate_form(source, BookingConfig.booking_field_spec()) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  end

  def form_valid?(_form), do: false
end
