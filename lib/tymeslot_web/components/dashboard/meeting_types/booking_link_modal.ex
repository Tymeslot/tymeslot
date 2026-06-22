defmodule TymeslotWeb.Components.Dashboard.MeetingTypes.BookingLinkModal do
  @moduledoc """
  Modal for changing a meeting type's booking link (its slug).

  Editing the slug rewrites the meeting type's URL, so any link the organiser
  has already shared stops working — the modal warns about this before applying
  and offers a "randomise" action to mint an unguessable link.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the change-booking-link modal.

  ## Attributes

    * `show` — whether the modal is visible (required)
    * `meeting_type` — the meeting type being edited (required when shown)
    * `slug_draft` — the slug currently in the input (required when shown)
    * `base_url` — everything before the slug, e.g. `https://host/alice` (required)
    * `myself` — the LiveComponent target for events (required)
  """
  attr :show, :boolean, required: true
  attr :meeting_type, :map, default: nil
  attr :slug_draft, :string, default: ""
  attr :base_url, :string, required: true
  attr :myself, :any, required: true

  @spec booking_link_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_link_modal(assigns) do
    ~H"""
    <CoreComponents.modal
      id="booking-link-modal"
      show={@show && @meeting_type != nil}
      on_cancel={JS.push("close_slug_modal", target: @myself)}
      size={:medium}
    >
      <:header>
        <div class="flex items-center gap-2">
          <CoreComponents.icon name="hero-link" class="w-5 h-5 text-turquoise-500" />
          <span>{dgettext("dashboard", "Change booking link")}</span>
        </div>
      </:header>

      <div :if={@meeting_type} class="space-y-5">
        <CoreComponents.info_box variant={:warning}>
          {dgettext("dashboard", 
            "Changing this link will stop any links you have already shared for this meeting type from working."
          )}
        </CoreComponents.info_box>

        <form id="booking-link-slug-form" phx-change="slug_draft_changed" phx-submit="confirm_slug_change" phx-target={@myself} class="space-y-2">
          <label for="booking-link-slug" class="block font-medium text-tymeslot-700">
            {dgettext("dashboard", "Link address")}
          </label>
          <div class="flex flex-wrap items-center gap-2">
            <span class="text-token-sm text-tymeslot-500 whitespace-nowrap">{@base_url}/</span>
            <input
              type="text"
              id="booking-link-slug"
              name="slug"
              value={@slug_draft}
              autocomplete="off"
              spellcheck="false"
              class="font-mono text-token-sm flex-1 min-w-[8rem] px-4 py-2.5 rounded-token-xl border-2 border-tymeslot-100 bg-white text-tymeslot-700 focus:border-turquoise-300 focus:outline-hidden"
            />
            <CoreComponents.action_button
              type="button"
              variant={:secondary}
              phx-click="randomise_slug"
              phx-target={@myself}
            >
              {dgettext("dashboard", "Randomise")}
            </CoreComponents.action_button>
          </div>
          <p class="text-token-sm text-tymeslot-500">
            {dgettext("dashboard", 
              "Use lowercase letters, numbers and hyphens. Randomise creates an unguessable link."
            )}
          </p>
        </form>
      </div>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button
            variant={:secondary}
            phx-click={JS.push("close_slug_modal", target: @myself)}
          >
            {dgettext("dashboard", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button
            variant={:primary}
            phx-click={JS.push("confirm_slug_change", target: @myself)}
          >
            {dgettext("dashboard", "Save link")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
