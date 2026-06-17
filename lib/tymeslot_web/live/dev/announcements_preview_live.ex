defmodule TymeslotWeb.Dev.AnnouncementsPreviewLive do
  @moduledoc """
  Dev-only preview page for feature announcements at `/dev/announcements`.

  Loads every entry from every registered `:announcement_catalogs` module —
  bypassing the per-user `seen` filter and the `published_at > user.inserted_at`
  cutoff in `Tymeslot.Announcements.list_for/1` — and immediately mounts the
  modal carousel so the page looks exactly like the dashboard would for a
  user with all announcements unseen.

  The modal is rendered with `preview?: true`, which short-circuits
  `Announcements.mark_seen!/2` — reloading the page restarts the carousel.
  """

  use TymeslotWeb, :live_view

  alias TymeslotWeb.Components.AnnouncementModalComponent

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Announcement preview")
     |> assign(:announcements, load_all_announcements())
     |> assign(:reopen_token, 0)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-tymeslot-50 p-8">
      <div class="mx-auto max-w-2xl space-y-4 text-center">
        <h1 class="display-md text-tymeslot-900">Announcement preview</h1>
        <p class="text-token-sm text-tymeslot-600">
          Dev-only. The modal below shows every announcement registered in
          <code class="rounded-token-sm bg-tymeslot-100 px-1 py-0.5 text-token-xs">:announcement_catalogs</code>
          — ignoring the seen list and the publish-date cutoff. Walking
          through or closing does not mark anything as seen.
        </p>

        <%= if @announcements == [] do %>
          <.info_box variant={:info}>
            No announcements are currently registered. Add entries to
            <code>Tymeslot.Announcements.Catalog</code>
            or any module listed under
            <code>:announcement_catalogs</code>
            and they will appear here.
          </.info_box>
        <% else %>
          <p class="text-token-xs text-tymeslot-500">
            {length(@announcements)} announcement(s) loaded.
          </p>
          <.action_button variant={:secondary} phx-click="reopen">
            Reopen modal
          </.action_button>
        <% end %>
      </div>

      <%!-- Modal mounts immediately on page load. The id varies per
      `@reopen_token` so each "Reopen modal" click remounts a fresh component
      instance — without this, internal `closed?` state from the previous
      session would persist and the modal would stay hidden. --%>
      <.live_component
        :if={@announcements != []}
        module={AnnouncementModalComponent}
        id={"dev-announcement-preview-#{@reopen_token}"}
        announcements={@announcements}
        current_user={nil}
        preview?={true}
      />
    </div>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("reopen", _params, socket) do
    {:noreply, update(socket, :reopen_token, &(&1 + 1))}
  end

  @impl Phoenix.LiveView
  def handle_info({:external_redirect, url}, socket) when is_binary(url) do
    {:noreply,
     socket
     |> put_flash(:info, "Preview mode: CTA would open #{url}")
     |> update(:reopen_token, &(&1 + 1))}
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
