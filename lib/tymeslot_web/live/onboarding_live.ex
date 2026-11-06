defmodule TymeslotWeb.OnboardingLive do
  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.OnboardingLive.CalendarHandlers
  alias TymeslotWeb.OnboardingLive.ChooseThemeStep
  alias TymeslotWeb.OnboardingLive.ConnectCalendarStep
  alias TymeslotWeb.OnboardingLive.DebugFixtures
  alias TymeslotWeb.OnboardingLive.Initializer
  alias TymeslotWeb.OnboardingLive.LivePreview
  alias TymeslotWeb.OnboardingLive.MeetingHandlers
  alias TymeslotWeb.OnboardingLive.MeetingStep
  alias TymeslotWeb.OnboardingLive.NavigationHandlers
  alias TymeslotWeb.OnboardingLive.OnboardingLayout
  alias TymeslotWeb.OnboardingLive.ProfileHandlers
  alias TymeslotWeb.OnboardingLive.ProfileStep
  alias TymeslotWeb.OnboardingLive.ReadyStep
  alias TymeslotWeb.OnboardingLive.StageFrame
  alias TymeslotWeb.OnboardingLive.StagePreviewModal
  alias TymeslotWeb.OnboardingLive.StepConfig
  alias TymeslotWeb.OnboardingLive.ThemeHandlers
  alias TymeslotWeb.OnboardingLive.TimezoneHandlers
  alias TymeslotWeb.OnboardingLive.WeekReveal
  alias TymeslotWeb.Themes.Core.Registry

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    if user.onboarding_completed_at && !debug?(socket) && !rejoining_live_step?(user, params) do
      {:ok,
       socket
       |> put_flash(
         :info,
         dgettext("onboarding_wizard", "You have already completed onboarding.")
       )
       |> redirect(to: ~p"/dashboard")}
    else
      {:ok,
       socket
       # Read by the root layout: load the stage's pre-paint fit.
       |> assign(:stage_prefit, true)
       |> Initializer.initialize(user)
       |> maybe_apply_fixture(params["fixture"])
       |> focus_headings_after_first_event()}
    end
  end

  # A host who has just kept their link has finished onboarding, but the
  # live step may still be on their screen: on a phone the mail fallback
  # opens Mail, the browser drops the socket, and the LiveView mounts again
  # when the host comes back. So `/onboarding/ready` stays open for an hour
  # after completion, the life of the preview token the step shows (a
  # reconnect comes back within minutes, `Onboarding.recently_completed?/1`);
  # after that, as for every other step, a completed account goes to the
  # dashboard and the wizard never reopens for a settled one.
  defp rejoining_live_step?(user, %{"step" => "ready"}), do: Onboarding.recently_completed?(user)

  defp rejoining_live_step?(_user, _params), do: false

  # Where a host may be is derived from their account (`StepConfig.resume_step/1`):
  # `/onboarding` lands on that step, and a step out of reach from it
  # (`StepConfig.reachable?/2`) patches back to it, so no step can be reached
  # before what it depends on is done. The static render cannot patch, so it
  # draws the step the connected render will land on, and the patch that
  # follows changes only the address.
  #
  # The address follows the step: Continue, Back and the share step's way
  # back to the calendar patch it to `/onboarding/<step>`, so a reload lands
  # on the step on screen and the browser's Back and Forward walk the steps
  # (within the same reach) as the wizard's own buttons do.
  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, uri, socket) do
    requested = requested_step(params["step"])

    socket =
      assign(socket,
        base_path: NavigationHandlers.base_path(uri),
        # Carried along when a control patches the address to another step.
        step_query: Map.delete(params, "step"),
        # Set by the OAuth return path of a host sent back from the share step
        # to the calendar step, and honoured only there: anywhere else it
        # would let a crafted link skip the steps in between later on.
        returning_to_share: requested == :connect_calendar and params["return"] == "share"
      )

    cond do
      not connected?(socket) ->
        step = landing_step(socket, requested)
        socket = assign(socket, :current_step, step)
        # The first paint draws the saved meeting: the meeting step edits it,
        # and the stage names it on every step, so it is there before the
        # socket connects and the page does not grow when it does.
        {:noreply, MeetingHandlers.load(socket, false)}

      # The address a control patched to (`NavigationHandlers.go_to_step/2`):
      # the step is on screen already.
      not is_nil(requested) and requested == socket.assigns.patched_step ->
        {:noreply, assign(socket, :patched_step, nil)}

      is_nil(requested) or not StepConfig.reachable?(requested, resume_step(socket)) ->
        {:noreply, push_patch(socket, to: step_path(socket, resume_step(socket), uri))}

      true ->
        {:noreply,
         socket |> NavigationHandlers.enter_by_address(requested) |> maybe_enter_share_state()}
    end
  end

  # A host who lands on the live step by its address (a reload) gets the
  # share state too, without counting another view of the step.
  defp maybe_enter_share_state(%{assigns: %{current_step: :ready}} = socket),
    do: NavigationHandlers.assign_share_state(socket)

  defp maybe_enter_share_state(socket), do: socket

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns = assign(assigns, :stage_caption, stage_caption(assigns))

    ~H"""
    <OnboardingLayout.onboarding_layout
      current_step={@current_step}
      booking_page_live={@booking_page_live}
      next_disabled={next_disabled?(assigns)}
      next_hint={next_hint(assigns)}
      focus_heading={@focus_heading}
      stage_announcement={stage_announcement(assigns)}
      stage_url={StageFrame.address(booking_host(), Map.get(@form_data, "username"))}
      stage_live={@current_step == :ready and @booking_page_live == true}
      stage_canvas={LivePreview.canvas(stage_theme(@profile), @theme_customization)}
      stage_theme={stage_theme(@profile)}
      stage_caption={@stage_caption}
      reserve_caption={
        LivePreview.caption_pending?(%{current_step: @current_step, stage_week: @stage_week})
      }
      stage_compact={@current_step == :connect_calendar and @booking_page_live != true}
      stage_iframe={stage_iframe(assigns)}
      show_nav={show_nav?(assigns)}
    >
      <:stage>
        <.stage_preview
          profile={@profile}
          current_step={@current_step}
          form_data={@form_data}
          theme_customization={@theme_customization}
          week={@stage_week}
          reveal_key={@reveal_key}
          meeting={MeetingHandlers.meeting_preview(assigns)}
        />
      </:stage>
      <%= case @current_step do %>
        <% :profile -> %>
          <ProfileStep.profile_step
            profile={@profile}
            form_data={@form_data}
            timezone_options={@timezone_options}
            timezone_editing={@timezone_editing}
            timezone_focus_change={@timezone_focus_change}
            link_suggested={@link_suggested}
            link_input={@link_input}
            timezone_dropdown_open={@timezone_dropdown_open}
            timezone_search={@timezone_search}
            form_errors={@form_errors}
            uploads={@uploads}
            avatar_url={@profile && Profiles.avatar_url(@profile, :thumb)}
          />
        <% :choose_theme -> %>
          <ChooseThemeStep.choose_theme_step
            profile={@profile}
            theme_options={@theme_options}
            theme_customization={@theme_customization}
            choices={@onboarding_choices}
            headline_form={@headline_form}
          />
        <% :connect_calendar -> %>
          <ConnectCalendarStep.connect_calendar_step
            calendar_state={@calendar_state}
            connected_calendars={@connected_calendars}
            booking_page_live={@booking_page_live}
            reconnecting={not is_nil(@reconnecting_calendar)}
            google_signup_email={@google_signup_email}
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
            caldav_discovering={@caldav_discovering}
          />
        <% :meeting -> %>
          <MeetingStep.meeting_step
            meeting_form={@meeting_form}
            meeting_errors={@meeting_errors}
            taken_names={@taken_names}
            hours_form={@hours_form}
            hours_open={@hours_open}
            video_integration={@video_integration}
          />
        <% :ready -> %>
          <ReadyStep.ready_step
            booking_url={@booking_url}
            page_live={@booking_page_live}
            kept_method={@kept_method}
            first_person_name={@first_person_name}
            first_person_email={@first_person_email}
            email={@current_user.email}
            handoff_qr={@handoff_qr}
            handoff_url={@handoff_url}
            handoff_ready={is_binary(@share_username)}
            finish_locked={NavigationHandlers.finish_locked?(assigns)}
          />
      <% end %>
    </OnboardingLayout.onboarding_layout>

    <StagePreviewModal.stage_preview_modal
      show={@show_stage_preview_modal}
      canvas={LivePreview.canvas(stage_theme(@profile), @theme_customization)}
      iframe_src={stage_iframe(assigns)}
    >
      <.stage_preview
        profile={@profile}
        current_step={@current_step}
        form_data={@form_data}
        theme_customization={@theme_customization}
        week={@stage_week}
        reveal_key={@reveal_key}
        meeting={MeetingHandlers.meeting_preview(assigns)}
        id="stage-expanded"
      />
    </StagePreviewModal.stage_preview_modal>
    """
  end

  # Both renders draw the host's own page from their profile. Only a host on
  # their very first visit, whose profile the connected mount creates, gets
  # a neutral skeleton in the static render.
  attr :profile, :any, required: true
  attr :current_step, :atom, required: true
  attr :form_data, :map, required: true
  attr :theme_customization, :any, required: true
  attr :week, :map, required: true
  attr :reveal_key, :integer, required: true

  attr :meeting, :map,
    default: nil,
    doc: "the meeting the page offers (`MeetingHandlers.meeting_preview/1`)"

  attr :id, :string, default: "stage", doc: "names this copy of the page"

  defp stage_preview(assigns) do
    ~H"""
    <LivePreview.preview_skeleton :if={is_nil(@profile)} />
    <LivePreview.live_preview
      :if={@profile}
      current_step={@current_step}
      booking_theme={stage_theme(@profile)}
      name={Map.get(@form_data, "full_name", "")}
      username={Map.get(@form_data, "username", "")}
      avatar_url={@profile.avatar && Profiles.avatar_url(@profile, :thumb)}
      headline={@profile.headline}
      theme_customization={@theme_customization}
      week={@week}
      reveal_key={@reveal_key}
      meeting={@meeting}
      today={Availability.today(@profile)}
      id={@id}
      booking_host={booking_host()}
    />
    """
  end

  # ------------------------------------------------------------------
  # Event handlers — Navigation
  # ------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_event("next_step", _params, socket) do
    NavigationHandlers.handle_next_step(socket)
  end

  def handle_event("return_to_calendar_step", _params, socket) do
    NavigationHandlers.handle_return_to_calendar_step(socket)
  end

  def handle_event("previous_step", _params, socket) do
    NavigationHandlers.handle_previous_step(socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Keeping the link (the live step)
  # ------------------------------------------------------------------

  def handle_event("keep_link", params, socket) do
    NavigationHandlers.handle_keep_link(socket, params)
  end

  def handle_event("finish_locked", _params, socket) do
    NavigationHandlers.handle_finish_locked(socket)
  end

  def handle_event("first_person_change", params, socket) do
    {:noreply,
     assign(socket,
       first_person_name: first_person_field(params["name"], ReadyStep.name_max_length()),
       first_person_email: first_person_field(params["email"], ReadyStep.email_max_length())
     )}
  end

  def handle_event("show_handoff_qr", _params, socket) do
    NavigationHandlers.handle_show_handoff_qr(socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Meeting and weekly hours
  # ------------------------------------------------------------------

  def handle_event("meeting_change", params, socket) do
    MeetingHandlers.handle_change(params, socket)
  end

  def handle_event("meeting_save", _params, socket) do
    MeetingHandlers.handle_save(socket)
  end

  def handle_event("meeting_suggestion", %{"index" => index}, socket) do
    MeetingHandlers.handle_suggestion(index, socket)
  end

  def handle_event("meeting_duration", %{"duration" => value}, socket) do
    MeetingHandlers.handle_duration(value, socket)
  end

  def handle_event("meeting_location", %{"location" => value}, socket) do
    MeetingHandlers.handle_location(value, socket)
  end

  def handle_event("hours_preset", %{"preset" => value}, socket) do
    MeetingHandlers.handle_hours_preset(value, socket)
  end

  def handle_event("hours_toggle_day", %{"day" => day}, socket) do
    MeetingHandlers.handle_toggle_day(day, socket)
  end

  def handle_event("hours_change", params, socket) do
    MeetingHandlers.handle_hours_change(params, socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Stage
  # ------------------------------------------------------------------

  def handle_event("try_booking", params, socket) do
    NavigationHandlers.handle_try_booking(socket, params)
  end

  def handle_event("expand_stage", _params, socket) do
    {:noreply, ModalHook.show_modal(socket, :stage_preview)}
  end

  def handle_event("close_stage_preview", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :stage_preview)}
  end

  # ------------------------------------------------------------------
  # Event handlers — Profile (basic settings + avatar)
  # ------------------------------------------------------------------

  def handle_event("validate_basic_settings", params, socket) do
    ProfileHandlers.handle_validate_basic_settings(params, socket)
  end

  def handle_event("link_blur", _params, socket) do
    ProfileHandlers.handle_link_blur(socket)
  end

  def handle_event("update_basic_settings", _params, socket) do
    NavigationHandlers.handle_next_step(socket)
  end

  def handle_event("validate_avatar", _params, socket) do
    {:noreply, socket}
  end

  # ------------------------------------------------------------------
  # Event handlers — Theme
  # ------------------------------------------------------------------

  def handle_event("select_theme", %{"theme" => theme_id}, socket) do
    ThemeHandlers.handle_select_theme(theme_id, socket)
  end

  def handle_event("select_onboarding_choice", %{"choice" => value}, socket) do
    ThemeHandlers.handle_select_choice(value, socket)
  end

  def handle_event("headline_change", params, socket) do
    ThemeHandlers.handle_headline_change(params, socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Calendar connection
  # ------------------------------------------------------------------

  def handle_event("select_calendar_option", %{"option" => option}, socket) do
    CalendarHandlers.handle_choose_provider(option, socket)
  end

  def handle_event("reconnect_calendar", %{"id" => id}, socket) do
    CalendarHandlers.handle_reconnect(id, socket)
  end

  def handle_event("cancel_caldav", _params, socket) do
    CalendarHandlers.handle_cancel_caldav(socket)
  end

  def handle_event("validate_caldav", params, socket) do
    CalendarHandlers.handle_validate_caldav(params, socket)
  end

  def handle_event("discover_caldav_calendars", params, socket) do
    CalendarHandlers.handle_discover_caldav(params, socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Timezone
  # ------------------------------------------------------------------

  def handle_event("edit_timezone", _params, socket) do
    TimezoneHandlers.handle_edit_timezone(socket)
  end

  def handle_event("toggle_timezone_dropdown", _params, socket) do
    TimezoneHandlers.handle_toggle_timezone_dropdown(socket)
  end

  def handle_event("close_timezone_dropdown", _params, socket) do
    TimezoneHandlers.handle_close_timezone_dropdown(socket)
  end

  def handle_event("search_timezone", %{"search" => search}, socket) do
    TimezoneHandlers.handle_search_timezone(search, socket)
  end

  def handle_event("search_timezone", %{"value" => search}, socket) do
    TimezoneHandlers.handle_search_timezone(search, socket)
  end

  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    TimezoneHandlers.handle_change_timezone(timezone, socket)
  end

  # ------------------------------------------------------------------
  # handle_async
  # ------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_async(:discover_caldav, result, socket) do
    CalendarHandlers.handle_discover_caldav_result(result, socket)
  end

  def handle_async(:week_preview, result, socket) do
    {:noreply, WeekReveal.handle_result(result, socket)}
  end

  # ------------------------------------------------------------------
  # handle_info
  # ------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_info({:flash, {type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end

  def handle_info({:week_preview_refresh, token}, socket) do
    {:noreply, WeekReveal.handle_refresh(token, socket)}
  end

  def handle_info({:week_preview_slow, key}, socket) do
    {:noreply, WeekReveal.handle_slow(key, socket)}
  end

  # The host opened the handoff link (the QR code) on another device.
  def handle_info({:onboarding, :preview_opened}, socket) do
    NavigationHandlers.handle_phone_opened(socket)
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  # The calendar step waits for a bookable calendar; the meeting step for
  # every field to be valid.
  defp next_disabled?(%{current_step: :connect_calendar} = assigns),
    do: assigns.booking_page_live != true

  defp next_disabled?(%{current_step: :meeting} = assigns), do: MeetingHandlers.invalid?(assigns)
  defp next_disabled?(_assigns), do: false

  # On a phone the field in error can be off screen, so the nav names it.
  defp next_hint(%{current_step: :meeting} = assigns), do: MeetingHandlers.blocking_error(assigns)
  defp next_hint(_assigns), do: nil

  # The live step has its own finish, and an open Apple or CalDAV form its
  # own Cancel and Connect: one set of actions on screen at a time.
  defp show_nav?(%{current_step: :ready}), do: false

  defp show_nav?(%{current_step: :connect_calendar, calendar_state: state})
       when state in [:connecting_apple, :connecting_caldav],
       do: false

  defp show_nav?(_assigns), do: true

  # On the live step the stage shows the real page once the socket is
  # connected and the page takes visitors.
  defp stage_iframe(%{current_step: :ready, booking_page_live: true} = assigns),
    do: assigns.owner_preview_url

  defp stage_iframe(_assigns), do: nil

  # A keep action's confirmation is what the live step announces.
  defp stage_announcement(%{current_step: :ready, kept_method: method}) when is_binary(method),
    do: ReadyStep.kept_label(method)

  defp stage_announcement(assigns), do: assigns.stage_caption || ""

  defp first_person_field(value, max_length) when is_binary(value),
    do: value |> String.replace("\x00", "") |> String.slice(0, max_length)

  defp first_person_field(_value, _max_length), do: ""

  defp debug?(socket), do: socket.assigns.live_action in [:debug_welcome, :debug_step]

  # The caption under the stage, which the live region announces too.
  defp stage_caption(assigns) do
    LivePreview.caption(%{
      current_step: assigns.current_step,
      booking_page_live: assigns.booking_page_live,
      booking_host: booking_host(),
      username: Map.get(assigns.form_data, "username", ""),
      stage_week: assigns.stage_week
    })
  end

  # A fixture only ever applies on the debug routes; elsewhere the parameter
  # is ignored. It applies once per mount, so a patch to another step does
  # not apply it (and read the week) again.
  defp maybe_apply_fixture(socket, name) do
    if debug?(socket), do: DebugFixtures.apply(socket, name), else: socket
  end

  # An unknown or retired step name (`welcome`, the old preference steps)
  # counts as no step at all, and so resumes like `/onboarding` does.
  defp requested_step(step) do
    if StepConfig.valid_step?(step), do: String.to_existing_atom(step)
  end

  defp landing_step(socket, requested) do
    resume = resume_step(socket)
    if requested && StepConfig.reachable?(requested, resume), do: requested, else: resume
  end

  defp resume_step(socket) do
    StepConfig.resume_step(%{
      username: socket.assigns.profile && socket.assigns.profile.username,
      bookable_calendar?: socket.assigns.booking_page_live == true
    })
  end

  # The query string travels with the patch, so a debug fixture or an OAuth
  # return flag survives the move to the resume step.
  defp step_path(socket, step, uri) do
    path = socket.assigns.base_path <> "/" <> Atom.to_string(step)

    case URI.parse(uri).query do
      nil -> path
      query -> path <> "?" <> query
    end
  end

  # Before the profile exists, the theme it will be created with.
  defp stage_theme(%{booking_theme: theme}) when is_binary(theme), do: theme
  defp stage_theme(_profile), do: Registry.default_theme_id()

  # A step change after the host's first action moves the focus to the new
  # step's heading; the page load, and the patch that lands a host on the
  # step they resume at, leave the focus where the browser put it.
  defp focus_headings_after_first_event(socket) do
    attach_hook(socket, :focus_heading, :handle_event, fn _event, _params, socket ->
      {:cont, assign(socket, :focus_heading, true)}
    end)
  end

  defp booking_host do
    String.replace(UrlBuilder.base_url(), ~r{^https?://}, "")
  end
end
