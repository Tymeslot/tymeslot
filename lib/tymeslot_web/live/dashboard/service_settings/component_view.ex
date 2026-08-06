defmodule TymeslotWeb.Dashboard.ServiceSettings.ComponentView do
  @moduledoc """
  Markup for the meeting (service) settings component.

  Extracted from `ServiceSettingsComponent` so that module stays focused on lifecycle
  and event routing, matching how `CalendarSettings.ComponentView` sits behind
  `CalendarSettingsComponent`. `settings/1` receives the component's assigns
  unchanged (its `render/1` delegates straight to it), so LiveView change
  tracking is preserved.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.BookingLinkModal
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.DeleteMeetingTypeModal
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponent
  alias TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent
  alias TymeslotWeb.Endpoint

  def settings(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header
        icon="hero-squares-2x2"
        title={dgettext("dashboard_integrations", "Meeting Settings")}
        saving={@saving}
      />

      <%= if (@show_edit_overlay && @editing_type) || @show_add_form do %>
        <%!-- Form View (Add or Edit) --%>
        <div
          id="meeting-type-config-view"
          phx-hook="ScrollReset"
          data-action={if @editing_type, do: "edit-#{@editing_type.id}", else: "new"}
          class="space-y-8"
        >
          <div class="flex items-start justify-between bg-white p-6 rounded-token-3xl border-2 border-tymeslot-50 shadow-sm">
            <.section_header
              level={2}
              icon="hero-squares-2x2"
              title={
                if @editing_type,
                  do: dgettext("dashboard_integrations", "Edit Meeting Type"),
                  else: dgettext("dashboard_integrations", "Add Meeting Type")
              }
            />
            <button
              phx-click={if @editing_type, do: "close_edit_overlay", else: "toggle_add_form"}
              phx-target={@myself}
              class="shrink-0 p-2 rounded-lg text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 transition-colors"
              title={dgettext("dashboard_integrations", "Close")}
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <div class="card-glass">
            <.live_component
              module={MeetingTypeForm}
              id={if @editing_type, do: "meeting-type-form-edit-#{@editing_type.id}", else: "meeting-type-form-new"}
              type={@editing_type}
              is_edit={!!@editing_type}
              video_integrations={@video_integrations}
              calendar_integrations={@calendar_integrations}
              parent_myself={@myself}
              saving={@saving}
              current_user={@current_user}
              client_ip={@client_ip}
              user_agent={@user_agent}
              form_errors={@form_errors}
              custom_questions_allowed={@custom_questions_allowed}
            />
          </div>

          <%!-- Booking link & visibility (existing types only; needs a username) --%>
          <div
            :if={@editing_type && booking_base_url(@profile)}
            class="card-glass space-y-6"
          >
            <div class="flex items-center gap-2">
              <.icon name="hero-link" class="w-5 h-5 text-turquoise-500" />
              <h3 class="font-semibold text-tymeslot-700 text-token-lg">
                {dgettext("dashboard_integrations", "Booking link & visibility")}
              </h3>
            </div>

            <div class="space-y-2">
              <label class="block font-medium text-tymeslot-700 text-token-sm">
                {dgettext("dashboard_integrations", "Direct booking link")}
              </label>
              <div class="flex flex-wrap items-center gap-2">
                <input
                  type="text"
                  readonly
                  value={"#{booking_base_url(@profile)}/#{MeetingTypes.effective_slug(@editing_type)}"}
                  class="font-mono text-token-sm flex-1 min-w-[12rem] px-4 py-2.5 rounded-token-xl border-2 border-tymeslot-100 bg-tymeslot-50 text-tymeslot-600 cursor-default"
                />
                <button
                  type="button"
                  id={"copy-booking-link-#{@editing_type.id}"}
                  phx-hook="CopyOnClick"
                  data-copy-text={"#{booking_base_url(@profile)}/#{MeetingTypes.effective_slug(@editing_type)}"}
                  data-copy-feedback={dgettext("dashboard_integrations", "Booking link copied!")}
                  class="whitespace-nowrap px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
                >
                  {dgettext("dashboard_integrations", "Copy")}
                </button>
                <.action_button
                  type="button"
                  variant={:secondary}
                  phx-click="open_slug_modal"
                  phx-target={@myself}
                >
                  {dgettext("dashboard_integrations", "Change link")}
                </.action_button>
              </div>
              <p class="text-token-sm text-tymeslot-500">
                {dgettext("dashboard_integrations", 
                  "Anyone with this link can book this meeting type directly, without seeing your other meeting types."
                )}
              </p>
            </div>

            <div class="flex items-center justify-between gap-4 pt-2 border-t-2 border-tymeslot-50">
              <div>
                <p class="font-medium text-tymeslot-700">
                  {dgettext("dashboard_integrations", "Hide from public booking page")}
                </p>
                <p class="text-token-sm text-tymeslot-500">
                  {dgettext("dashboard_integrations", "When on, this meeting type is reachable only through its direct link.")}
                </p>
              </div>
              <button
                type="button"
                phx-click="toggle_private"
                phx-value-id={@editing_type.id}
                phx-target={@myself}
                role="switch"
                aria-checked={@editing_type.is_private}
                aria-label={dgettext("dashboard_integrations", "Hide from public booking page")}
                class={[
                  "relative inline-flex h-5 w-9 shrink-0 cursor-pointer rounded-full border-2 transition-colors duration-200 ease-in-out focus:outline-hidden focus:ring-2 focus:ring-turquoise-500 focus:ring-offset-2",
                  if(@editing_type.is_private,
                    do: "bg-turquoise-500 border-turquoise-500",
                    else: "bg-tymeslot-300 border-tymeslot-300"
                  )
                ]}
              >
                <span class={[
                  "pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                  if(@editing_type.is_private, do: "translate-x-4", else: "translate-x-0")
                ]} />
              </button>
            </div>
          </div>

          <BookingLinkModal.booking_link_modal
            show={@show_slug_modal}
            meeting_type={@slug_modal_type}
            slug_draft={@slug_draft}
            base_url={booking_base_url(@profile) || ""}
            myself={@myself}
          />
        </div>
      <% else %>
        <%!-- Normal View --%>
        <div class="space-y-10">
          <%!-- Meeting Types Section --%>
          <div class="space-y-6">
            <MeetingTypesListComponent.meeting_types_section
              meeting_types={@meeting_types}
              show_add_form={@show_add_form}
              editing_type={@editing_type}
              currency={@payment_currency}
              parent_myself={@myself}
            />
          </div>

    <%!-- Scheduling Settings --%>
          <div>
            <.live_component
              module={SchedulingSettingsComponent}
              id="scheduling-settings"
              profile={@profile}
              client_ip={@client_ip}
              user_agent={@user_agent}
            />
          </div>
        </div>

    <%!-- Delete Meeting Type Modal --%>
        <DeleteMeetingTypeModal.delete_meeting_type_modal
          show={@show_delete_meeting_type_modal}
          meeting_type={@delete_meeting_type_modal_data}
          myself={@myself}
        />
      <% end %>

    <%!-- Add spacing after content to prevent flush bottom --%>
      <div class="pb-8"></div>
    </div>
    """
  end

  # The public base of a meeting type's booking link, e.g. "https://host/alice".
  # Returns nil when the profile has no username yet (link UI is then hidden).
  defp booking_base_url(%{username: username}) when is_binary(username) and username != "" do
    Endpoint.url() <> "/" <> username
  end

  defp booking_base_url(_profile), do: nil
end
