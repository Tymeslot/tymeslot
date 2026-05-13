defmodule TymeslotWeb.Dev.AnnouncementsPreviewLive do
  @moduledoc """
  Dev-only preview page for feature announcements at `/dev/announcements`.

  Loads every entry from every registered `:announcement_catalogs` module —
  bypassing the per-user `seen` filter and the `published_at > user.inserted_at`
  cutoff in `Tymeslot.Announcements.list_for/1` — so designers and authors can
  see exactly how each card renders without registering accounts or clearing
  `user_seen_announcements` rows.

  The modal is rendered with `preview?: true`, which short-circuits
  `Announcements.mark_seen!/2` — reloading the page restarts the carousel.
  """

  use TymeslotWeb, :live_view

  alias Tymeslot.Announcements.Announcement
  alias TymeslotWeb.Components.AnnouncementModalComponent

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Announcement preview")
     |> assign(:announcements, load_all_announcements())
     |> assign(:modal_announcements, [])
     |> assign(:open_token, 0)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-tymeslot-50 p-8">
      <div class="mx-auto max-w-5xl space-y-6">
        <header class="space-y-2">
          <h1 class="display-md text-tymeslot-900">Announcement preview</h1>
          <p class="text-token-base text-tymeslot-600">
            Dev-only. Shows every announcement registered in
            <code class="rounded-token-sm bg-tymeslot-100 px-1 py-0.5 text-token-sm">:announcement_catalogs</code>
            — ignoring the seen list and the publish-date cutoff.
            Marking-seen is disabled, so reloading restarts the carousel.
          </p>
        </header>

        <%= if @announcements == [] do %>
          <.info_box variant={:info}>
            No announcements are currently registered. Add entries to
            <code>Tymeslot.Announcements.Catalog</code>
            or any module listed under
            <code>:announcement_catalogs</code>
            and they will appear here.
          </.info_box>
        <% else %>
          <div class="flex items-center justify-between gap-4">
            <p class="text-token-sm text-tymeslot-500">
              {length(@announcements)} announcement(s) loaded.
            </p>
            <.action_button
              variant={:primary}
              phx-click="preview_all"
              disabled={@announcements == []}
            >
              Preview all in carousel
            </.action_button>
          </div>

          <ul class="space-y-4">
            <li :for={announcement <- @announcements}>
              <.announcement_card announcement={announcement} />
            </li>
          </ul>
        <% end %>
      </div>

      <%!-- Modal renders only when a preview has been triggered. The id
      varies per click (`@open_token`) so each open mounts a fresh component
      instance — without this, internal `closed?` state from the previous
      session would persist and the modal would stay hidden. --%>
      <.live_component
        :if={@modal_announcements != []}
        module={AnnouncementModalComponent}
        id={"dev-announcement-preview-#{@open_token}"}
        announcements={@modal_announcements}
        current_user={nil}
        preview?={true}
      />
    </div>
    """
  end

  attr :announcement, Announcement, required: true

  defp announcement_card(assigns) do
    ~H"""
    <article class="rounded-token-lg border border-tymeslot-200 bg-white p-6 shadow-sm">
      <div class="flex items-start justify-between gap-4">
        <div class="space-y-1">
          <h2 class="text-token-lg font-semibold text-tymeslot-900">
            {@announcement.title}
          </h2>
          <p class="text-token-xs text-tymeslot-500">
            key:
            <code class="rounded-token-sm bg-tymeslot-100 px-1">{@announcement.key}</code>
            &middot; published {Calendar.strftime(@announcement.published_at, "%Y-%m-%d %H:%M UTC")}
          </p>
        </div>
        <.action_button
          variant={:outline}
          phx-click="preview_one"
          phx-value-key={@announcement.key}
        >
          Preview this
        </.action_button>
      </div>

      <p class="mt-4 text-token-base leading-relaxed text-tymeslot-700">
        {@announcement.body}
      </p>

      <dl class="mt-4 grid grid-cols-1 gap-2 text-token-sm text-tymeslot-600 sm:grid-cols-3">
        <div>
          <dt class="font-medium text-tymeslot-500">Image</dt>
          <dd>{@announcement.image_path || "—"}</dd>
        </div>
        <div>
          <dt class="font-medium text-tymeslot-500">CTA label</dt>
          <dd>{@announcement.cta_label || "—"}</dd>
        </div>
        <div>
          <dt class="font-medium text-tymeslot-500">CTA path</dt>
          <dd>{@announcement.cta_path || "—"}</dd>
        </div>
      </dl>
    </article>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("preview_all", _params, socket) do
    {:noreply, open_modal(socket, socket.assigns.announcements)}
  end

  def handle_event("preview_one", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.announcements, &(&1.key == key)) do
      nil -> {:noreply, socket}
      announcement -> {:noreply, open_modal(socket, [announcement])}
    end
  end

  defp open_modal(socket, announcements) do
    socket
    |> assign(:modal_announcements, announcements)
    |> update(:open_token, &(&1 + 1))
  end

  @impl Phoenix.LiveView
  def handle_info({:announcement_cta_navigate, path}, socket) when is_binary(path) do
    {:noreply,
     socket
     |> put_flash(:info, "Preview mode: CTA would navigate to #{path}")
     |> assign(:modal_announcements, [])}
  end

  defp load_all_announcements do
    :tymeslot
    |> Application.get_env(:announcement_catalogs, [])
    |> Enum.flat_map(&safe_list/1)
    |> Enum.sort_by(& &1.published_at, DateTime)
  end

  defp safe_list(catalog) do
    catalog.list()
  rescue
    _error -> []
  end
end
