defmodule TymeslotWeb.Dashboard.ProfileSettings.UsernameChangeModal do
  @moduledoc """
  Confirmation modal shown before an existing username is replaced.

  The username is the first segment of every public URL the product produces —
  the booking page, each event link, the organiser overview and every poll
  invitation — and there is no alias, redirect or history behind it. Changing
  it breaks every link already shared, including the ones inside confirmation
  emails this product has already sent, and the visitor holding one gets a 404
  with no way back. None of that is recoverable, so the organiser is told
  exactly what they are about to break before it happens rather than after.

  Stateless function component rendered by `UsernameFormComponent`. Cancel and
  confirm dispatch `cancel_username_change` and `confirm_username_change` back
  to the parent component (`@myself`), which owns the modal's state and
  performs the update.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :pending_username, :string, default: nil
  attr :current_username, :string, required: true
  attr :display_url, :string, required: true
  attr :open_poll_count, :integer, required: true
  attr :myself, :any, required: true

  @spec username_change_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def username_change_modal(assigns) do
    ~H"""
    <.modal
      :if={@pending_username}
      id="username-change-modal"
      show={true}
      on_cancel={JS.push("cancel_username_change", target: @myself)}
      size={:medium}
    >
      <:header>
        <div class="flex items-center gap-3">
          <div class="w-10 h-10 rounded-token-xl flex items-center justify-center border bg-amber-50 border-amber-100">
            <.icon name="hero-exclamation-triangle" class="w-6 h-6 text-amber-500" />
          </div>
          <span class="text-token-xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_profile", "Change your URL to %{username}?",
              username: @pending_username
            )}
          </span>
        </div>
      </:header>

      <div class="space-y-4">
        <.info_box variant={:warning}>
          {dgettext(
            "dashboard_profile",
            "%{url} will stop working immediately. Links that already point there cannot be recovered.",
            url: "#{@display_url}/#{@current_username}"
          )}
        </.info_box>

        <p class="text-tymeslot-700 font-medium">
          {dgettext("dashboard_profile", "This breaks:")}
        </p>

        <ul class="space-y-2 text-tymeslot-600">
          <li class="flex items-start gap-2">
            <.icon name="hero-x-mark-mini" class="w-5 h-5 text-red-500 shrink-0 mt-0.5" />
            <span>
              {dgettext("dashboard_profile", "your booking page and every event link on it")}
            </span>
          </li>
          <li :if={@open_poll_count > 0} class="flex items-start gap-2">
            <.icon name="hero-x-mark-mini" class="w-5 h-5 text-red-500 shrink-0 mt-0.5" />
            <span>
              {dngettext(
                "dashboard_profile",
                "%{count} poll still waiting on votes",
                "%{count} polls still waiting on votes",
                @open_poll_count
              )}
            </span>
          </li>
          <li class="flex items-start gap-2">
            <.icon name="hero-x-mark-mini" class="w-5 h-5 text-red-500 shrink-0 mt-0.5" />
            <span>
              {dgettext(
                "dashboard_profile",
                "links inside confirmation and reminder emails already sent"
              )}
            </span>
          </li>
        </ul>

        <p class="text-token-sm text-tymeslot-500 font-medium">
          {dgettext(
            "dashboard_profile",
            "Once released, %{username} can be claimed by anyone else.",
            username: @current_username
          )}
        </p>
      </div>

      <:footer>
        <div class="flex gap-4">
          <button
            type="button"
            phx-click="cancel_username_change"
            phx-target={@myself}
            class="btn-secondary flex-1 py-4"
          >
            {dgettext("common", "Cancel")}
          </button>
          <button
            type="button"
            phx-click="confirm_username_change"
            phx-target={@myself}
            phx-disable-with={dgettext("dashboard_profile", "Saving...")}
            class="btn-primary flex-1 py-4"
          >
            {dgettext("dashboard_profile", "Change URL")}
          </button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
