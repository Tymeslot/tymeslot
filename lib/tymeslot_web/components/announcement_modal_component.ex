defmodule TymeslotWeb.Components.AnnouncementModalComponent do
  @moduledoc """
  Stacked carousel modal that walks an authenticated user through any
  unseen feature announcements on dashboard mount.

  Receives the list of `Tymeslot.Announcements.Announcement` structs from
  the parent LiveView (assigned by `AnnouncementsHook`). Internal state
  tracks the current index and whether the user has dismissed the modal.

  Dismissing the stack (closing, cancelling, taking a CTA, or reaching the
  end) marks **every** announcement seen — not just the current one — so a
  user who waves the modal away is not nagged with the rest on next login.

  Per the gotcha in `CLAUDE.md`, navigation/flash from a LiveComponent does
  not propagate; the component sends an `{:external_redirect, url}` message to
  the parent for CTA navigation (the docs live outside the app) rather than
  navigating directly.
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Announcements

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, current_index: 0, closed?: false, preview?: false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    current = Enum.at(assigns.announcements, assigns.current_index)
    total = length(assigns.announcements)
    on_last? = assigns.current_index + 1 == total
    has_cta? = (current && is_binary(current.cta_label)) and is_binary(current.cta_docs_slug)

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:total, total)
      |> assign(:on_last?, on_last?)
      |> assign(:has_cta?, has_cta?)

    ~H"""
    <div id={@id}>
      <%!-- Render modal only when there is unseen content and the user has not dismissed it. --%>
      <.modal
        :if={@announcements != [] and not @closed? and @current}
        id={"#{@id}-modal"}
        show={true}
        on_cancel={JS.push("close", target: @myself)}
      >
        <:header>
          <span class="flex flex-col gap-2">
            <span class="inline-flex items-center gap-1.5 self-start rounded-full bg-turquoise-600 px-3 py-1 text-token-sm font-bold uppercase tracking-wide text-white shadow-sm">
              <.icon name="hero-sparkles-mini" class="h-4 w-4" />
              {dgettext("onboarding", "New feature")}
            </span>
            <span>{@current.title}</span>
          </span>
        </:header>

        <div aria-live="polite" aria-atomic="true">
          <div :if={@current.image_path} class="mb-4">
            <img src={@current.image_path} alt="" class="w-full h-auto rounded-token-lg" />
          </div>

          <p class="text-token-base text-tymeslot-700 leading-relaxed">{@current.body}</p>

          <ul :if={@current.bullets != []} class="mt-3 space-y-2">
            <li
              :for={item <- @current.bullets}
              class="flex items-start gap-2 text-token-base text-tymeslot-700 leading-relaxed"
            >
              <.icon name="hero-check-circle-mini" class="mt-0.5 h-5 w-5 shrink-0 text-turquoise-600" />
              <span>{item}</span>
            </li>
          </ul>
        </div>

        <:footer>
          <div class="flex items-center justify-between gap-3 w-full">
            <button
              type="button"
              class="text-token-sm text-tymeslot-500 hover:text-tymeslot-700 disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
              disabled={@current_index == 0}
              phx-click="back"
              phx-target={@myself}
            >
              {dgettext("onboarding", "Back")}
            </button>

            <span
              :if={@total > 1}
              class="text-token-xs text-tymeslot-400"
              data-test="step-indicator"
            >
              {dgettext("onboarding", "%{current} / %{total}",
                current: @current_index + 1,
                total: @total
              )}
            </span>
            <span :if={@total <= 1}></span>

            <div class="flex items-center gap-2">
              <%= cond do %>
                <% @on_last? and @has_cta? -> %>
                  <.action_button variant={:secondary} phx-click="cta" phx-target={@myself}>
                    {@current.cta_label}
                  </.action_button>
                  <.action_button variant={:primary} phx-click="next" phx-target={@myself}>
                    {dgettext("onboarding", "Got it")}
                  </.action_button>
                <% @on_last? -> %>
                  <.action_button variant={:primary} phx-click="next" phx-target={@myself}>
                    {dgettext("onboarding", "Got it")}
                  </.action_button>
                <% @has_cta? -> %>
                  <.action_button variant={:secondary} phx-click="cta" phx-target={@myself}>
                    {@current.cta_label}
                  </.action_button>
                  <.action_button variant={:primary} phx-click="next" phx-target={@myself}>
                    {dgettext("onboarding", "Next")}
                  </.action_button>
                <% true -> %>
                  <.action_button variant={:primary} phx-click="next" phx-target={@myself}>
                    {dgettext("onboarding", "Next")}
                  </.action_button>
              <% end %>
            </div>
          </div>
        </:footer>
      </.modal>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("next", _params, socket) do
    case Enum.at(socket.assigns.announcements, socket.assigns.current_index) do
      nil ->
        {:noreply, socket}

      current ->
        new_index = socket.assigns.current_index + 1

        if new_index >= length(socket.assigns.announcements) do
          # Reaching the end is a terminal action — mark the whole stack seen.
          mark_all_seen(socket)
          {:noreply, assign(socket, closed?: true)}
        else
          # Persist progress for the item we are leaving so a mid-stack reload
          # resumes where the user was rather than restarting the carousel.
          maybe_mark_seen(socket, current)
          {:noreply, assign(socket, current_index: new_index)}
        end
    end
  end

  def handle_event("back", _params, socket) do
    new_index = max(socket.assigns.current_index - 1, 0)
    {:noreply, assign(socket, current_index: new_index)}
  end

  def handle_event("close", _params, socket) do
    mark_all_seen(socket)
    {:noreply, assign(socket, closed?: true)}
  end

  def handle_event("cta", _params, socket) do
    case Enum.at(socket.assigns.announcements, socket.assigns.current_index) do
      nil ->
        {:noreply, assign(socket, closed?: true)}

      current ->
        mark_all_seen(socket)
        maybe_send_cta_navigation(current)
        {:noreply, assign(socket, closed?: true)}
    end
  end

  defp maybe_send_cta_navigation(%{cta_docs_slug: slug}) when is_binary(slug) do
    send(self(), {:external_redirect, Announcements.docs_url(slug)})
  end

  defp maybe_send_cta_navigation(_announcement), do: :ok

  # Preview mode (used by the dev preview route) keeps the carousel
  # idempotent — without it, walking through once would write to
  # user_seen_announcements and hide every entry on the next reload.
  defp maybe_mark_seen(%{assigns: %{preview?: true}}, _current), do: :ok

  defp maybe_mark_seen(socket, current) do
    Announcements.mark_seen!(socket.assigns.current_user, current.key)
  end

  # Dismissing the stack marks every announcement seen, not just the current
  # one, so the user is not re-shown the rest on their next visit.
  defp mark_all_seen(%{assigns: %{preview?: true}}), do: :ok

  defp mark_all_seen(socket) do
    Enum.each(socket.assigns.announcements, fn announcement ->
      Announcements.mark_seen!(socket.assigns.current_user, announcement.key)
    end)
  end
end
