defmodule TymeslotWeb.OnboardingLive do
  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.OnboardingLive.CalendarHandlers
  alias TymeslotWeb.OnboardingLive.ChooseThemeStep
  alias TymeslotWeb.OnboardingLive.ConnectCalendarStep
  alias TymeslotWeb.OnboardingLive.DebugFixtures
  alias TymeslotWeb.OnboardingLive.Initializer
  alias TymeslotWeb.OnboardingLive.LivePreview
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
  alias TymeslotWeb.OnboardingLive.ThemePreviewModal
  alias TymeslotWeb.OnboardingLive.TimezoneHandlers
  alias TymeslotWeb.Themes.Core.Registry

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if user.onboarding_completed_at && !debug?(socket) do
      {:ok,
       socket
       |> put_flash(
         :info,
         dgettext("onboarding_wizard", "You have already completed onboarding.")
       )
       |> redirect(to: ~p"/dashboard")}
    else
      {:ok, socket |> Initializer.initialize(user) |> focus_headings_after_first_event()}
    end
  end

  # Where a host may be is derived from their account (`StepConfig.resume_step/1`):
  # `/onboarding` lands on that step, and a step out of reach from it
  # (`StepConfig.reachable?/2`) patches back to it, so no step can be reached
  # before what it depends on is done. The static render has no profile yet,
  # so the check waits for the connected one.
  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, uri, socket) do
    requested = requested_step(params["step"])

    socket =
      socket
      |> assign(
        base_path: NavigationHandlers.base_path(uri),
        # Set by the OAuth return path of a host sent back from the share step
        # to the calendar step, and honoured only there: anywhere else it
        # would let a crafted link skip the steps in between later on.
        returning_to_share: requested == :connect_calendar and params["return"] == "share"
      )
      |> maybe_apply_fixture(params["fixture"])

    cond do
      not connected?(socket) ->
        {:noreply, assign(socket, :current_step, requested || :profile)}

      is_nil(requested) or not StepConfig.reachable?(requested, resume_step(socket)) ->
        {:noreply, push_patch(socket, to: step_path(socket, resume_step(socket), uri))}

      true ->
        {:noreply, assign(socket, :current_step, requested)}
    end
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <OnboardingLayout.onboarding_layout
      current_step={@current_step}
      booking_page_live={@booking_page_live}
      next_disabled={
        @current_step == :connect_calendar and is_nil(@calendar_choice) and !@booking_page_live
      }
      focus_heading={@focus_heading}
      stage_announcement={@stage_announcement}
      stage_url={StageFrame.address(booking_host(), Map.get(@form_data, "username"))}
      stage_live={@current_step == :ready and @booking_page_live == true}
      stage_canvas={@profile && LivePreview.canvas(stage_theme(@profile), @theme_customization)}
      stage_caption={
        LivePreview.caption(%{
          current_step: @current_step,
          booking_page_live: @booking_page_live,
          booking_host: booking_host(),
          username: Map.get(@form_data, "username", "")
        })
      }
    >
      <:stage>
        <.stage_preview
          profile={@profile}
          current_step={@current_step}
          form_data={@form_data}
          theme_customization={@theme_customization}
          calendar_connected={@connected_calendars != [] or @calendar_choice != nil}
        />
      </:stage>
      <%= case @current_step do %>
        <% :profile -> %>
          <ProfileStep.profile_step
            profile={@profile}
            form_data={@form_data}
            timezone_options={@timezone_options}
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
            picker={@theme_picker}
          />
        <% :connect_calendar -> %>
          <ConnectCalendarStep.connect_calendar_step
            calendar_state={@calendar_state}
            connected_calendars={@connected_calendars}
            calendar_choice={@calendar_choice}
            google_signup_email={@google_signup_email}
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
            caldav_discovering={@caldav_discovering}
          />
        <% :meeting -> %>
          <MeetingStep.meeting_step />
        <% :ready -> %>
          <ReadyStep.ready_step booking_url={@booking_url} page_live={@booking_page_live} />
      <% end %>
    </OnboardingLayout.onboarding_layout>

    <StagePreviewModal.stage_preview_modal
      show={@show_stage_preview_modal}
      canvas={@profile && LivePreview.canvas(stage_theme(@profile), @theme_customization)}
    >
      <.stage_preview
        profile={@profile}
        current_step={@current_step}
        form_data={@form_data}
        theme_customization={@theme_customization}
        calendar_connected={@connected_calendars != [] or @calendar_choice != nil}
      />
    </StagePreviewModal.stage_preview_modal>

    <%!-- Real booking-page preview --%>
    <ThemePreviewModal.theme_preview_modal
      show={@show_theme_preview_modal}
      url={@theme_preview_modal_data}
    />
    """
  end

  # The disconnected (dead) render has no profile yet, so it can't know the
  # user's theme or colours. Rendering the real preview with default colours
  # there would flash the wrong theme the instant the socket connects, so it
  # shows a neutral skeleton until then.
  attr :profile, :any, required: true
  attr :current_step, :atom, required: true
  attr :form_data, :map, required: true
  attr :theme_customization, :any, required: true
  attr :calendar_connected, :boolean, required: true

  defp stage_preview(assigns) do
    ~H"""
    <LivePreview.preview_skeleton :if={is_nil(@profile)} />
    <LivePreview.live_preview
      :if={@profile}
      current_step={@current_step}
      booking_theme={stage_theme(@profile)}
      name={Map.get(@form_data, "full_name", "")}
      username={Map.get(@form_data, "username", "")}
      avatar_url={Profiles.avatar_url(@profile, :thumb)}
      theme_customization={@theme_customization}
      calendar_connected={@calendar_connected}
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

  def handle_event("share_booking_link", params, socket) do
    NavigationHandlers.handle_share_booking_link(socket, params["channel"])
  end

  def handle_event("previous_step", _params, socket) do
    NavigationHandlers.handle_previous_step(socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Stage
  # ------------------------------------------------------------------

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

  def handle_event("update_basic_settings", _params, socket) do
    NavigationHandlers.handle_next_step(socket)
  end

  def handle_event("validate_avatar", _params, socket) do
    {:noreply, socket}
  end

  # ------------------------------------------------------------------
  # Event handlers — Theme & preview
  # ------------------------------------------------------------------

  def handle_event("select_theme", %{"theme" => theme_id}, socket) do
    ThemeHandlers.handle_select_theme(theme_id, socket)
  end

  def handle_event("select_onboarding_choice", %{"choice" => value}, socket) do
    ThemeHandlers.handle_select_choice(value, socket)
  end

  def handle_event("show_all_themes", _params, socket) do
    ThemeHandlers.handle_theme_picker(:all, socket)
  end

  def handle_event("show_theme_stories", _params, socket) do
    ThemeHandlers.handle_theme_picker(:stories, socket)
  end

  def handle_event("preview_booking_page", _params, socket) do
    ThemeHandlers.handle_preview_booking_page(socket)
  end

  def handle_event("close_theme_preview", _params, socket) do
    ThemeHandlers.handle_close_theme_preview(socket)
  end

  # ------------------------------------------------------------------
  # Event handlers — Calendar connection
  # ------------------------------------------------------------------

  def handle_event("select_calendar_option", %{"option" => option}, socket) do
    CalendarHandlers.handle_select_option(option, socket)
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

  # ------------------------------------------------------------------
  # handle_info
  # ------------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_info({:flash, {type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp debug?(socket), do: socket.assigns.live_action in [:debug_welcome, :debug_step]

  # A fixture only ever applies on the debug routes; elsewhere the parameter
  # is ignored.
  defp maybe_apply_fixture(socket, name) do
    if debug?(socket), do: DebugFixtures.apply(socket, name), else: socket
  end

  # An unknown or retired step name (`welcome`, the old preference steps)
  # counts as no step at all, and so resumes like `/onboarding` does.
  defp requested_step(step) do
    if StepConfig.valid_step?(step), do: String.to_existing_atom(step)
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

  defp stage_theme(profile), do: profile.booking_theme || Registry.default_theme_id()

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
